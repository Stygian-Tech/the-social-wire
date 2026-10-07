package topicreadcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"golang.org/x/sync/errgroup"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

type CircleReader struct {
	Moderation  *ModerationService
	Auth        gatewaycore.AuthContext
	FollowProof string
}

func (r *CircleReader) ViewerFollows(ctx context.Context, viewer string) (FollowList, error) {
	if r.FollowProof == "" || r.Auth.DID != viewer {
		return FollowList{}, ErrUnavailable
	}
	base, err := r.Moderation.Resolver.ResolvePDS(ctx, viewer)
	if err != nil {
		return FollowList{}, ErrUnavailable
	}
	headers := http.Header{}
	headers.Set("Authorization", strings.TrimSpace(r.Auth.Authorization))
	headers.Set("DPoP", strings.TrimSpace(r.FollowProof))
	result := FollowList{ActorDID: viewer, FolloweeDIDs: []string{}}
	var cursor *string
	for {
		if err := ctx.Err(); err != nil {
			return FollowList{}, err
		}
		query := url.Values{"repo": {viewer}, "collection": {"app.bsky.graph.follow"}, "limit": {"100"}, "reverse": {"false"}}
		if cursor != nil {
			query.Set("cursor", *cursor)
		}
		doc, err := r.privateFollowDocument(ctx, base, query, headers.Clone())
		if err != nil {
			return FollowList{}, err
		}
		records, _ := doc["records"].([]any)
		for _, raw := range records {
			record, _ := raw.(map[string]any)
			value, _ := record["value"].(map[string]any)
			if subject, ok := value["subject"].(string); ok {
				result.FolloweeDIDs = append(result.FolloweeDIDs, subject)
			}
		}
		next, present := doc["cursor"].(string)
		if !present {
			result.Complete = true
			return result, nil
		}
		if cursor != nil && next == *cursor {
			return FollowList{}, ErrUnavailable
		}
		cursor = &next
	}
}
func (r *CircleReader) PublicFollows(ctx context.Context, actors []string) ([]FollowList, error) {
	actors = append([]string{}, actors...)
	sort.Strings(actors)
	result := make([]FollowList, len(actors))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(16)
	for i, actor := range actors {
		g.Go(func() error {
			value := FollowList{ActorDID: actor, FolloweeDIDs: []string{}}
			doc, err := r.Moderation.fetchJSON(gctx, r.publicBase(), "app.bsky.graph.getFollows", url.Values{"actor": {actor}, "limit": {"100"}}, nil)
			if err == nil {
				rows, _ := doc["follows"].([]any)
				for _, raw := range rows {
					row, _ := raw.(map[string]any)
					if did, ok := row["did"].(string); ok {
						value.FolloweeDIDs = append(value.FolloweeDIDs, did)
					}
				}
				_, present := doc["cursor"].(string)
				value.Complete = !present
			}
			result[i] = value
			return nil
		})
	}
	_ = g.Wait()
	return result, nil
}
func (r *CircleReader) publicBase() string {
	if r.Moderation.PublicBase != "" {
		return r.Moderation.PublicBase
	}
	return "https://public.api.bsky.app"
}

type CircleIdentity struct {
	DID         string  `json:"did"`
	Handle      string  `json:"handle"`
	DisplayName *string `json:"displayName,omitempty"`
	AvatarURL   *string `json:"avatarUrl,omitempty"`
}

func (r *CircleReader) Profiles(ctx context.Context, actors []string) (map[string]CircleIdentity, error) {
	actors = append([]string{}, actors...)
	sort.Strings(actors)
	result := map[string]CircleIdentity{}
	stringPtr := func(raw any) *string {
		if value, ok := raw.(string); ok {
			return &value
		}
		return nil
	}
	for start := 0; start < len(actors); start += 25 {
		query := url.Values{"actors": actors[start:min(start+25, len(actors))]}
		doc, err := r.Moderation.fetchJSONWithTimeout(ctx, r.publicBase(), "app.bsky.actor.getProfiles", query, nil, 10*time.Second)
		if err != nil {
			return nil, ErrUnavailable
		}
		rows, _ := doc["profiles"].([]any)
		for _, raw := range rows {
			row, _ := raw.(map[string]any)
			did, dok := row["did"].(string)
			handle, hok := row["handle"].(string)
			if dok && hok {
				result[did] = CircleIdentity{did, handle, stringPtr(row["displayName"]), stringPtr(row["avatar"])}
			}
		}
	}
	return result, nil
}

type CircleActivityReader struct {
	DB     *sql.DB
	Corpus corpuscore.Store
	Hasher *wirecore.ActorHasher
}

func (r *CircleActivityReader) RecentActivity(ctx context.Context, actors []string, now time.Time) (map[string]time.Time, error) {
	result := map[string]time.Time{}
	if len(actors) == 0 {
		return result, nil
	}
	byHash := map[string]string{}
	for _, did := range actors {
		hash, err := r.Hasher.Hash(did)
		if err != nil {
			return nil, err
		}
		byHash[hash] = did
	}
	hashes := keysString(byHash)
	since := now.Add(-7 * 24 * time.Hour)
	if r.DB != nil {
		rows, err := r.DB.QueryContext(ctx, `SELECT actor_key_hash,MAX(occurred_at) FROM wire_signal_events WHERE actor_key_hash=ANY($1::text[]) AND occurred_at>=$2 GROUP BY actor_key_hash`, hashes, since)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var hash string
			var at time.Time
			if err = rows.Scan(&hash, &at); err != nil {
				return nil, err
			}
			if did, ok := byHash[hash]; ok {
				result[did] = at
			}
		}
		return result, rows.Err()
	}
	if r.Corpus == nil {
		return nil, ErrUnavailable
	}
	for start := 0; start < len(hashes); start += 5000 {
		page, err := r.Corpus.CircleCandidates(ctx, corpuscore.CandidateRequest{ActorHashes: hashes[start:min(start+5000, len(hashes))], Language: "und", Since: since, Limit: 500}, now)
		if err != nil {
			return nil, corpusError(err)
		}
		for _, story := range page.Stories {
			for _, fact := range story.Facts {
				if did, ok := byHash[fact.ActorHash]; ok && fact.OccurredAt.After(result[did]) {
					result[did] = fact.OccurredAt
				}
			}
		}
	}
	return result, nil
}
func keysString(values map[string]string) []string {
	result := []string{}
	for key := range values {
		result = append(result, key)
	}
	sort.Strings(result)
	return result
}

func (r *CircleReader) privateFollowDocument(ctx context.Context, base string, query url.Values, headers http.Header) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	headers.Set("Accept", "application/json")
	transport := r.Moderation.HTTP
	if transport == nil {
		transport = thinappviewcore.PublicHTTP{}
	}
	target := strings.TrimRight(base, "/") + "/xrpc/com.atproto.repo.listRecords?" + query.Encode()
	status, _, body, err := transport.Get(ctx, target, headers, 1<<20, 0)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, ErrUnavailable
	}
	var doc map[string]any
	if json.Unmarshal(body, &doc) != nil || doc == nil {
		return nil, ErrUnavailable
	}
	if _, ok := doc["records"].([]any); !ok {
		return nil, ErrUnavailable
	}
	return doc, nil
}
