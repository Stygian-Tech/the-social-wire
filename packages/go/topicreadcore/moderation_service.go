package topicreadcore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"golang.org/x/sync/errgroup"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var ModerationMethods = []string{"app.bsky.actor.getPreferences", "app.bsky.graph.getBlocks", "app.bsky.graph.getMutes", "app.bsky.graph.getListMutes", "app.bsky.graph.getListBlocks"}

func ExtractProofs(raw string, count int) ([]string, error) {
	proofs := strings.Split(raw, ",")
	if len(proofs) != count {
		return nil, ErrModerationUnavailable
	}
	for _, proof := range proofs {
		if proof == "" {
			return nil, ErrModerationUnavailable
		}
	}
	return proofs, nil
}

func NewModerationService(resolver PDSResolver, transport thinappviewcore.PublicGetter) *ModerationService {
	return &ModerationService{Resolver: resolver, HTTP: transport, Cache: &ModerationCache{}}
}

type ModerationService struct {
	Resolver   PDSResolver
	HTTP       thinappviewcore.PublicGetter
	Cache      *ModerationCache
	PublicBase string
}

func (m *ModerationService) Require(ctx context.Context, auth *gatewaycore.AuthContext, rawProofs string, now time.Time) (*ModerationSnapshot, error) {
	if auth == nil || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		return nil, nil
	}
	proofs, err := ExtractProofs(rawProofs, len(ModerationMethods))
	if fresh := m.Cache.Fresh(auth.DID, now); fresh != nil {
		return fresh, nil
	}
	if err != nil {
		if stale := m.Cache.Usable(auth.DID, now); stale != nil {
			return stale, nil
		}
		return nil, err
	}
	return m.RequireProofs(ctx, *auth, proofs, now)
}
func (m *ModerationService) RequireProofs(ctx context.Context, auth gatewaycore.AuthContext, proofs []string, now time.Time) (*ModerationSnapshot, error) {
	if fresh := m.Cache.Fresh(auth.DID, now); fresh != nil {
		return fresh, nil
	}
	if len(proofs) != len(ModerationMethods) {
		if stale := m.Cache.Usable(auth.DID, now); stale != nil {
			return stale, nil
		}
		return nil, ErrModerationUnavailable
	}
	deadline, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	value, err := m.fetch(deadline, auth, proofs, now)
	if err == nil {
		m.Cache.Store(auth.DID, value)
		return &value, nil
	}
	if stale := m.Cache.Usable(auth.DID, now); stale != nil {
		return stale, nil
	}
	return nil, ErrModerationUnavailable
}
func (m *ModerationService) fetch(ctx context.Context, auth gatewaycore.AuthContext, proofs []string, now time.Time) (ModerationSnapshot, error) {
	resolve, cancel := context.WithTimeout(ctx, 5*time.Second)
	base, err := m.Resolver.ResolvePDS(resolve, auth.DID)
	cancel()
	if err != nil || base == "" {
		return ModerationSnapshot{}, ErrModerationUnavailable
	}
	documents := make([]map[string]any, 5)
	group, gctx := errgroup.WithContext(ctx)
	for i, method := range ModerationMethods {
		group.Go(func() error {
			query := url.Values{}
			if i > 0 {
				query.Set("limit", "100")
			}
			headers := http.Header{}
			headers.Set("Authorization", auth.Authorization)
			headers.Set("DPoP", proofs[i])
			doc, err := m.fetchJSON(gctx, base, method, query, headers)
			if err != nil {
				return err
			}
			if i > 0 {
				if _, exists := doc["cursor"]; exists {
					return ErrModerationUnavailable
				}
			}
			documents[i] = doc
			return nil
		})
	}
	if err := group.Wait(); err != nil {
		return ModerationSnapshot{}, err
	}
	value := ModerationSnapshot{BlockedDIDs: map[string]bool{}, MutedDIDs: map[string]bool{}, MutedWords: []string{}, InterestTags: map[string]bool{}, FetchedAt: now}
	profiles := func(document map[string]any, key string, destination map[string]bool) {
		rows, _ := document[key].([]any)
		for _, raw := range rows {
			if row, ok := raw.(map[string]any); ok {
				if did, ok := row["did"].(string); ok {
					destination[did] = true
				}
			}
		}
	}
	profiles(documents[1], "blocks", value.BlockedDIDs)
	profiles(documents[2], "mutes", value.MutedDIDs)
	preferences, _ := documents[0]["preferences"].([]any)
	for _, raw := range preferences {
		preference, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		kind, _ := preference["$type"].(string)
		if strings.Contains(kind, "mutedWordsPref") {
			items, _ := preference["items"].([]any)
			for _, item := range items {
				row, ok := item.(map[string]any)
				if !ok {
					continue
				}
				if _, expires := row["expiresAt"]; expires {
					continue
				}
				word, _ := row["value"].(string)
				word = strings.ToLower(strings.TrimSpace(word))
				if word != "" {
					value.MutedWords = append(value.MutedWords, word)
				}
			}
		}
		if strings.Contains(kind, "interestsPref") {
			tags, _ := preference["tags"].([]any)
			for _, raw := range tags {
				if tag, ok := raw.(string); ok {
					tag = strings.ToLower(strings.TrimSpace(tag))
					if tag != "" {
						value.InterestTags[tag] = true
					}
				}
			}
		}
	}
	lists := map[string]bool{}
	for _, doc := range documents[3:] {
		rows, _ := doc["lists"].([]any)
		for _, raw := range rows {
			if row, ok := raw.(map[string]any); ok {
				if uri, ok := row["uri"].(string); ok {
					lists[uri] = true
				}
			}
		}
	}
	count := 0
	for uri := range lists {
		if count >= 200 {
			break
		}
		count++
		var cursor *string
		complete := false
		for range 20 {
			query := url.Values{"list": {uri}, "limit": {"100"}}
			if cursor != nil {
				query.Set("cursor", *cursor)
			}
			base := m.PublicBase
			if base == "" {
				base = "https://public.api.bsky.app"
			}
			doc, err := m.fetchJSON(ctx, base, "app.bsky.graph.getList", query, nil)
			if err != nil {
				return ModerationSnapshot{}, err
			}
			items, _ := doc["items"].([]any)
			for _, raw := range items {
				row, _ := raw.(map[string]any)
				subject, _ := row["subject"].(map[string]any)
				if did, ok := subject["did"].(string); ok {
					value.BlockedDIDs[did] = true
				}
			}
			next, present := doc["cursor"].(string)
			cursor = &next
			if !present {
				complete = true
				break
			}
		}
		if !complete {
			return ModerationSnapshot{}, ErrModerationUnavailable
		}
	}
	return value, nil
}
func (m *ModerationService) fetchJSON(ctx context.Context, base, method string, query url.Values, headers http.Header) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	target := strings.TrimRight(base, "/") + "/xrpc/" + method
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	if headers == nil {
		headers = http.Header{}
	}
	headers.Set("Accept", "application/json")
	transport := m.HTTP
	if transport == nil {
		transport = thinappviewcore.PublicHTTP{}
	}
	status, _, body, err := transport.Get(ctx, target, headers, 2<<20, 0)
	if err != nil || status != 200 {
		return nil, ErrModerationUnavailable
	}
	var document map[string]any
	if json.Unmarshal(body, &document) != nil || document == nil {
		return nil, ErrModerationUnavailable
	}
	return document, nil
}
