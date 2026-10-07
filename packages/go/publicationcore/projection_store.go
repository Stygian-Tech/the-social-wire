package publicationcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"sort"
	"time"
)

type ProjectionStore struct{ DB *sql.DB }

func allSidebarRows(sidebar Sidebar) []SidebarRow {
	rows := append([]SidebarRow{}, sidebar.AllPublicationRows...)
	rows = append(rows, sidebar.MyPublications...)
	rows = append(rows, sidebar.SubscribedUnfoldered...)
	rows = append(rows, sidebar.FollowingTabPublications...)
	for _, section := range sidebar.FolderSections {
		rows = append(rows, section.Publications...)
	}
	return rows
}
func (s ProjectionStore) Persist(ctx context.Context, sidebar Sidebar, replaceAll bool) error {
	sections := map[string]map[string]bool{}
	add := func(id, key string) {
		if sections[id] == nil {
			sections[id] = map[string]bool{}
		}
		sections[id][key] = true
	}
	for _, row := range sidebar.MyPublications {
		add(row.PublicationID, "my")
		add(row.PublicationID, "subscribed")
	}
	for _, row := range sidebar.SubscribedUnfoldered {
		add(row.PublicationID, "subscribed:unfoldered")
		add(row.PublicationID, "subscribed")
	}
	for _, row := range sidebar.FollowingTabPublications {
		add(row.PublicationID, "following")
	}
	for _, section := range sidebar.FolderSections {
		for _, row := range section.Publications {
			add(row.PublicationID, "folder:"+section.FolderRKey)
			add(row.PublicationID, "subscribed")
		}
	}
	for _, row := range sidebar.AllPublicationRows {
		if sections[row.PublicationID] == nil {
			add(row.PublicationID, "all")
		}
	}
	byID := map[string]SidebarRow{}
	for _, row := range allSidebarRows(sidebar) {
		byID[row.PublicationID] = row
	}
	scopes := []map[string]any{}
	ids := []string{}
	for id := range byID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		row := byID[id]
		sectionKeys := []string{}
		for key := range sections[id] {
			sectionKeys = append(sectionKeys, key)
		}
		sort.Strings(sectionKeys)
		scope := row.AppViewScope
		scopes = append(scopes, map[string]any{"publication_id": id, "author_did": scope.AuthorDID, "publication_at_uri": scope.PublicationATURI, "publication_scope_at_uris": scope.PublicationScopeATURIs, "publication_site_urls": scope.PublicationSiteURLs, "scope_keys": appviewcore.PublicationSiteKeys(scope.ReadScope(id)), "section_keys": sectionKeys})
	}
	feeds := []map[string]string{{"feed_kind": "subscribed", "feed_id": ""}, {"feed_kind": "following", "feed_id": ""}}
	memberships := []map[string]string{}
	known := map[string]bool{}
	member := func(kind, id, pub string) {
		key := kind + "\x00" + id + "\x00" + pub
		if !known[key] {
			memberships = append(memberships, map[string]string{"feed_kind": kind, "feed_id": id, "publication_id": pub})
			known[key] = true
		}
	}
	for _, row := range sidebar.SubscribedUnfoldered {
		member("subscribed", "", row.PublicationID)
	}
	for _, row := range sidebar.FollowingTabPublications {
		member("following", "", row.PublicationID)
	}
	for _, section := range sidebar.FolderSections {
		feeds = append(feeds, map[string]string{"feed_kind": "folder", "feed_id": section.FolderRKey})
		for _, row := range section.Publications {
			member("subscribed", "", row.PublicationID)
			member("folder", section.FolderRKey, row.PublicationID)
		}
	}
	scopeJSON, e := json.Marshal(scopes)
	if e != nil {
		return e
	}
	feedJSON, _ := json.Marshal(feeds)
	membershipJSON, _ := json.Marshal(memberships)
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "appview-publications:"+sidebar.ViewerDID); e != nil {
		return e
	}
	if replaceAll {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			if _, e = tx.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", sidebar.ViewerDID); e != nil {
				return e
			}
		}
	}
	at := time.Now().UTC()
	if _, e = tx.ExecContext(ctx, `INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,publication_scope_at_uris,publication_site_urls,scope_keys,section_keys,updated_at) SELECT $1,x.publication_id,x.author_did,x.publication_at_uri,COALESCE(x.publication_scope_at_uris,'[]'),COALESCE(x.publication_site_urls,'[]'),COALESCE(x.scope_keys,'[]'),COALESCE(x.section_keys,'[]'),$3 FROM jsonb_to_recordset($2::jsonb) AS x(publication_id text,author_did text,publication_at_uri text,publication_scope_at_uris jsonb,publication_site_urls jsonb,scope_keys jsonb,section_keys jsonb) ON CONFLICT(viewer_did,publication_id)DO UPDATE SET author_did=EXCLUDED.author_did,publication_at_uri=EXCLUDED.publication_at_uri,publication_scope_at_uris=EXCLUDED.publication_scope_at_uris,publication_site_urls=EXCLUDED.publication_site_urls,scope_keys=EXCLUDED.scope_keys,section_keys=EXCLUDED.section_keys,updated_at=EXCLUDED.updated_at`, sidebar.ViewerDID, string(scopeJSON), at); e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO appview_viewer_feeds(viewer_did,feed_kind,feed_id,updated_at) SELECT $1,x.feed_kind,x.feed_id,$3 FROM jsonb_to_recordset($2::jsonb)AS x(feed_kind text,feed_id text)ON CONFLICT(viewer_did,feed_kind,feed_id)DO UPDATE SET updated_at=EXCLUDED.updated_at`, sidebar.ViewerDID, string(feedJSON), at); e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO appview_feed_publications(viewer_did,feed_kind,feed_id,publication_id) SELECT $1,x.feed_kind,x.feed_id,x.publication_id FROM jsonb_to_recordset($2::jsonb)AS x(feed_kind text,feed_id text,publication_id text)ON CONFLICT DO NOTHING`, sidebar.ViewerDID, string(membershipJSON)); e != nil {
		return e
	}
	return tx.Commit()
}
func (s ProjectionStore) Scope(ctx context.Context, viewer, id string) (*AppViewScope, error) {
	var result AppViewScope
	var uris, sites string
	e := s.DB.QueryRowContext(ctx, `SELECT author_did,publication_at_uri,publication_scope_at_uris::text,publication_site_urls::text FROM appview_publication_scopes WHERE viewer_did=$1 AND publication_id=$2`, viewer, id).Scan(&result.AuthorDID, &result.PublicationATURI, &uris, &sites)
	if e == sql.ErrNoRows {
		return nil, nil
	}
	if e != nil {
		return nil, e
	}
	if e = json.Unmarshal([]byte(uris), &result.PublicationScopeATURIs); e != nil {
		return nil, e
	}
	if e = json.Unmarshal([]byte(sites), &result.PublicationSiteURLs); e != nil {
		return nil, e
	}
	return &result, nil
}
