package podcastcore

import (
	"context"
	"encoding/json"
)

// Search bounds decryption and advances over nonmatches without storing private plaintext indexes.
func (s *Store) Search(ctx context.Context, viewer string, request SearchRequest) (SearchResponse, error) {
	if err := request.Validate(); err != nil {
		return SearchResponse{}, err
	}
	if request.Scope != nil && *request.Scope != "library" {
		return SearchResponse{}, ErrInvalidRequest
	}
	binding := SearchBinding(viewer, request)
	cursor, err := DecodeSearchCursor(request.Cursor, binding)
	if err != nil {
		return SearchResponse{}, err
	}
	entity, after := -1, ""
	if cursor != nil {
		entity = cursor.Entity
		after = cursor.ID
	}
	kind := "all"
	if request.Kind != nil {
		kind = *request.Kind
	}
	snapshot, err := s.State(ctx, viewer)
	if err != nil {
		return SearchResponse{}, err
	}
	native, rss := []string{}, []string{}
	hidden := map[string]bool{}
	for _, link := range snapshot.State.ManualLinks {
		native = append(native, link.ProtocolShowID)
		rss = append(rss, link.RSSShowID)
		hidden[link.ProtocolShowID] = true
	}
	rows, err := s.DB.QueryContext(ctx, `WITH links AS (SELECT DISTINCT ON (native_show_id) native_show_id,rss_show_id FROM unnest($1::text[],$2::text[]) WITH ORDINALITY AS mapping(native_show_id,rss_show_id,ordinal) WHERE EXISTS(SELECT 1 FROM podcast_subscriptions s WHERE s.viewer_did=$3 AND s.show_id=rss_show_id) ORDER BY native_show_id,ordinal),catalog AS (SELECT 0 AS entity,s.id,s.id AS show_id,s.show_json::text AS payload,false AS is_private FROM podcast_shows s JOIN podcast_subscriptions v ON v.show_id=s.id WHERE v.viewer_did=$3 UNION ALL SELECT 0,id,id,show_data,true FROM podcast_private_shows WHERE viewer_did=$3 AND $4 UNION ALL SELECT 1,e.id,COALESCE(l.rss_show_id,e.show_id),e.episode_json::text,false FROM podcast_episodes e JOIN podcast_subscriptions v ON v.show_id=e.show_id LEFT JOIN links l ON l.native_show_id=e.show_id WHERE v.viewer_did=$3 AND NOT EXISTS(SELECT 1 FROM podcast_episodes rss WHERE rss.show_id=l.rss_show_id AND rss.guid=e.guid AND e.guid IS NOT NULL) UNION ALL SELECT 1,id,show_id,episode_data,true FROM podcast_private_episodes WHERE viewer_did=$3 AND $4) SELECT entity,id,payload,is_private,show_id FROM catalog WHERE ($5='all' OR ($5='shows' AND entity=0) OR ($5='episodes' AND entity=1)) AND ($6::text IS NULL OR show_id=$6) AND (entity,id)>($7,$8) ORDER BY entity,id LIMIT 501`, native, rss, viewer, s.Private != nil, kind, request.ShowID, entity, after)
	if err != nil {
		return SearchResponse{}, err
	}
	defer rows.Close()
	limit := 20
	if request.Limit != nil {
		limit = *request.Limit
	}
	response := SearchResponse{Shows: []Show{}, Episodes: []Episode{}, Candidates: []DirectoryCandidate{}}
	scanned := 0
	var last *SearchCursor
	for rows.Next() {
		if scanned >= 500 || len(response.Shows)+len(response.Episodes) >= limit {
			response.HasMore = true
			break
		}
		var entity int
		var id, payload, showID string
		var private bool
		if err := rows.Scan(&entity, &id, &payload, &private, &showID); err != nil {
			return SearchResponse{}, err
		}
		scanned++
		last = &SearchCursor{Binding: binding, Entity: entity, ID: id}
		if private {
			storage, err := s.requirePrivate()
			if err != nil {
				return SearchResponse{}, err
			}
			kind := "show"
			if entity == 1 {
				kind = "episode"
			}
			payload, err = storage.Open(payload, viewer, kind, id)
			if err != nil {
				return SearchResponse{}, err
			}
		}
		if entity == 0 {
			var show Show
			if err := json.Unmarshal([]byte(payload), &show); err != nil {
				return SearchResponse{}, err
			}
			if private {
				show = VisibleShow(show)
			}
			if !hidden[id] && SearchMatches(request.Query, show.Title, show.Description, show.Hosts) {
				response.Shows = append(response.Shows, show)
			}
		} else {
			var episode Episode
			if err := json.Unmarshal([]byte(payload), &episode); err != nil {
				return SearchResponse{}, err
			}
			if private {
				episode = VisibleEpisode(episode)
			}
			episode.ShowID = showID
			episode.ChapterSourceURL = nil
			if SearchMatches(request.Query, episode.Title, episode.Description, nil) {
				response.Episodes = append(response.Episodes, episode)
			}
		}
	}
	if err := rows.Err(); err != nil {
		return SearchResponse{}, err
	}
	if response.HasMore && last != nil {
		encoded, err := last.Encode()
		if err != nil {
			return SearchResponse{}, err
		}
		response.Cursor = &encoded
	}
	return response, nil
}
