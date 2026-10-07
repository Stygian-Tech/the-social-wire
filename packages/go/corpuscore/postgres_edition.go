package corpuscore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"sort"
	"strconv"
	"strings"
	"time"
)

type editionProof struct {
	ModulePrefix string     `json:"modulePrefix"`
	ModuleKeys   []string   `json:"moduleKeys"`
	Stories      [][]string `json:"stories"`
	Accounts     []string   `json:"accounts"`
	HasMore      bool       `json:"hasMore"`
}
type cachedEdition struct {
	Value Edition      `json:"value"`
	Proof editionProof `json:"proof"`
}

func regionValue(region *string) string {
	if region == nil {
		return "default"
	}
	return *region
}
func (p editionProof) matches(revision string, region *string) bool {
	modules := []string{}
	items := [][]string{}
	type profile struct {
		position int
		did      string
	}
	profiles := []profile{}
	var continuation *bool
	for _, token := range strings.Split(revision, "\n") {
		var fields []any
		if json.Unmarshal([]byte(token), &fields) != nil || len(fields) == 0 {
			return false
		}
		kind, ok := fields[0].(string)
		if !ok {
			return false
		}
		switch kind {
		case "generation":
		case "module":
			if len(fields) < 2 {
				return false
			}
			key, ok := fields[1].(string)
			if !ok {
				return false
			}
			modules = append(modules, key)
		case "item":
			if len(fields) < 4 {
				return false
			}
			module, ok := fields[1].(string)
			id, ok2 := fields[3].(string)
			if !ok || !ok2 {
				return false
			}
			items = append(items, []string{module, id})
		case "account":
			if len(fields) < 3 {
				return false
			}
			position, ok := fields[1].(float64)
			did, ok2 := fields[2].(string)
			if !ok || !ok2 || position != float64(int(position)) {
				return false
			}
			profiles = append(profiles, profile{int(position), did})
		case "continuation":
			if len(fields) != 2 {
				return false
			}
			value, ok := fields[1].(bool)
			if !ok {
				return false
			}
			continuation = &value
		default:
			return false
		}
	}
	prefix := ""
	if regionValue(region) == "outside-us" {
		for _, module := range modules {
			if strings.HasPrefix(module, "outside-us:") {
				prefix = "outside-us:"
				break
			}
		}
	}
	selected := func(key string) bool {
		if prefix == "" {
			return !strings.Contains(key, ":")
		}
		return strings.HasPrefix(key, prefix)
	}
	expectedModules := []string{}
	expectedItems := [][]string{}
	for _, m := range modules {
		if selected(m) {
			expectedModules = append(expectedModules, m)
		}
	}
	for _, item := range items {
		if selected(item[0]) {
			expectedItems = append(expectedItems, item)
		}
	}
	sort.Slice(profiles, func(i, j int) bool { return profiles[i].position < profiles[j].position })
	accounts := []string{}
	for _, p := range profiles[:min(10, len(profiles))] {
		accounts = append(accounts, p.did)
	}
	return p.ModulePrefix == prefix && sameStrings(p.ModuleKeys, expectedModules) && samePairs(p.Stories, expectedItems) && sameStrings(p.Accounts, accounts) && continuation != nil && *continuation == p.HasMore
}
func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	a = append([]string{}, a...)
	b = append([]string{}, b...)
	sort.Strings(a)
	sort.Strings(b)
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
func samePairs(a, b [][]string) bool {
	encode := func(values [][]string) []string {
		result := []string{}
		for _, v := range values {
			data, _ := json.Marshal(v)
			result = append(result, string(data))
		}
		return result
	}
	return sameStrings(encode(a), encode(b))
}
func (s *PostgreSQLStore) editionRevision(ctx context.Context, id string) (string, error) {
	return s.revisionRows(ctx, `
      SELECT token FROM (
        SELECT 'generation' AS kind, '' AS ordering,
          json_build_array('generation', cache_revision, continuation_ordinal)::text AS token
        FROM wire_serving.edition_generations WHERE generation_id = $1::uuid
        UNION ALL
        SELECT 'module', module_key, json_build_array('module', module_key, cache_revision)::text
        FROM wire_serving.edition_modules WHERE generation_id = $1::uuid
        UNION ALL
        SELECT 'item', module_key || ':' || module_position::text,
          json_build_array('item', module_key, module_position, canonical_key, cache_revision)::text
        FROM wire_serving.edition_module_items WHERE generation_id = $1::uuid
        UNION ALL
        SELECT 'account', position::text,
          json_build_array('account', position, subject_did, cache_revision)::text
        FROM wire_serving.edition_talked_accounts WHERE generation_id = $1::uuid
        UNION ALL
        SELECT 'continuation', '', json_build_array('continuation', EXISTS(
          SELECT 1 FROM wire_serving.ranked_items AS ranked
          JOIN wire_serving.edition_generations AS edition USING (generation_id)
          WHERE ranked.generation_id = $1::uuid AND ranked.position >= edition.continuation_ordinal
        ))::text
      ) AS revisions ORDER BY kind, ordering, token
      `, id)
}
func (s *PostgreSQLStore) Edition(ctx context.Context, q EditionQuery, now time.Time) (Edition, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return Edition{}, err
	}
	gen, err := s.activeGeneration(ctx, q.Language, now)
	if err != nil {
		return Edition{}, err
	}
	if gen == nil {
		return s.fallbackEdition(ctx, q, now)
	}
	var payload cachedEdition
	load := func(ctx context.Context) (cachedEdition, error) { return s.loadEdition(ctx, gen, q.Region, now) }
	if s.Cache == nil {
		payload, err = load(ctx)
	} else {
		revision, e := s.editionRevision(ctx, gen.id)
		if e != nil {
			return Edition{}, e
		}
		payload, err = cachedValue(ctx, s.Cache, []string{"edition", "actor-v2", strings.ToUpper(gen.id), q.Language, regionValue(q.Region)}, revision, now, GenerationLifetime(gen.expires, now), func(ctx context.Context) (string, error) { return s.editionRevision(ctx, gen.id) }, func(value cachedEdition) bool { return value.Proof.matches(revision, q.Region) }, load)
	}
	if err != nil {
		return Edition{}, err
	}
	result := payload.Value
	if len(result.LeadStories)+len(result.PublicationPanels)+len(result.StoryRails)+len(result.GeneralStories)+len(result.TrendingStories) == 0 {
		return s.fallbackEdition(ctx, q, now)
	}
	stale := now.Sub(gen.generated) > 10*time.Minute
	result.Source = "ranked"
	if stale {
		result.Source = "stale_generation"
	}
	result.Degraded = gen.recovering || stale
	if result.SourceActorKeysByItemID == nil {
		result.SourceActorKeysByItemID = map[string]string{}
	}
	return result, nil
}
func (s *PostgreSQLStore) loadEdition(ctx context.Context, g *generation, region *string, now time.Time) (cachedEdition, error) {
	generationRows, err := s.query(ctx, `SELECT algorithm_version,continuation_ordinal FROM wire_serving.edition_generations WHERE generation_id=$1::uuid LIMIT 1`, g.id)
	if err != nil {
		return cachedEdition{}, err
	}
	if len(generationRows) == 0 {
		return cachedEdition{}, ErrContractMismatch
	}
	algorithm := generationRows[0].String(0)
	ordinal := generationRows[0].Int(1)
	if generationRows[0].err != nil {
		return cachedEdition{}, generationRows[0].err
	}
	prefix := ""
	if regionValue(region) == "outside-us" {
		rows, e := s.query(ctx, `SELECT EXISTS(SELECT 1 FROM wire_serving.edition_modules WHERE generation_id=$1::uuid AND module_key LIKE 'outside-us:%')`, g.id)
		if e != nil {
			return cachedEdition{}, e
		}
		if len(rows) != 1 {
			return cachedEdition{}, ErrContractMismatch
		}
		if rows[0].Bool(0) {
			prefix = "outside-us:"
		}
		if rows[0].err != nil {
			return cachedEdition{}, rows[0].err
		}
	}
	itemRows, err := s.query(ctx, `SELECT module_key,module_position,canonical_key,canonical_url,representative_uri,title,summary,published_at,thumbnail_url,source_name,source_domain,publication_id,author_name,provenance::text,author_key,reason_codes::text,publication_key,publication_homepage_url,publication_icon_url FROM wire_serving.edition_module_items WHERE generation_id=$1::uuid AND ($2='' AND POSITION(':' IN module_key)=0 OR $2<>'' AND module_key LIKE $3) ORDER BY module_key,module_position`, g.id, prefix, prefix+"%")
	if err != nil {
		return cachedEdition{}, err
	}
	items := map[string][]wirecore.FeedItem{}
	actors := map[string]string{}
	proof := editionProof{ModulePrefix: prefix, ModuleKeys: []string{}, Stories: [][]string{}, Accounts: []string{}}
	for _, r := range itemRows {
		key := r.String(0)
		item := decodeItem(r, 2, r.String(15), 16)
		items[key] = append(items[key], item)
		proof.Stories = append(proof.Stories, []string{key, item.ItemID})
		if actor := r.OptionalString(14); actor != nil {
			actors[item.ItemID] = *actor
		}
		if r.err != nil {
			return cachedEdition{}, r.err
		}
	}
	moduleRows, err := s.query(ctx, `SELECT module_key,module_kind,title,position,reason_code,publication_key,publication_name,publication_domain,publication_homepage_url,publication_icon_url FROM wire_serving.edition_modules WHERE generation_id=$1::uuid AND ($2='' AND POSITION(':' IN module_key)=0 OR $2<>'' AND module_key LIKE $3) ORDER BY position`, g.id, prefix, prefix+"%")
	if err != nil {
		return cachedEdition{}, err
	}
	result := wirecore.Edition{AlgorithmVersion: algorithm, GenerationID: g.id, GeneratedAt: g.generated, Language: g.language, Source: "ranked", Degraded: g.recovering, LeadStories: []wirecore.FeedItem{}, PublicationPanels: []wirecore.PublicationPanel{}, StoryRails: []wirecore.StoryRail{}, GeneralStories: []wirecore.FeedItem{}, TrendingStories: []wirecore.FeedItem{}, TalkedAboutAccounts: []wirecore.TalkedAboutAccount{}}
	for _, r := range moduleRows {
		key, kind := r.String(0), r.String(1)
		proof.ModuleKeys = append(proof.ModuleKeys, key)
		stories := items[key]
		if stories == nil {
			stories = []wirecore.FeedItem{}
		}
		switch kind {
		case "top_stories":
			result.LeadStories = stories[:min(4, len(stories))]
		case "publication_spotlight":
			if r.values[5] == nil || r.values[6] == nil || r.values[7] == nil {
				return cachedEdition{}, ErrContractMismatch
			}
			pub := wirecore.EditionPublication{Key: r.String(5), Name: r.String(6), Domain: r.String(7), HomepageURL: r.OptionalString(8), IconURL: r.OptionalString(9)}
			if len(stories) > 0 {
				pub.ID = stories[0].Source.Publication
			}
			result.PublicationPanels = append(result.PublicationPanels, wirecore.PublicationPanel{Publication: pub, Stories: stories[:min(3, len(stories))]})
		case "story_rail":
			if r.values[2] == nil || r.values[4] == nil {
				return cachedEdition{}, ErrContractMismatch
			}
			reason := wirecore.ReasonCode(r.String(4))
			if !validReason(reason) {
				return cachedEdition{}, ErrContractMismatch
			}
			result.StoryRails = append(result.StoryRails, wirecore.StoryRail{ID: strings.TrimPrefix(key, prefix), Title: r.String(2), Reason: reason, Stories: stories[:min(10, len(stories))]})
		case "general":
			result.GeneralStories = stories
		case "trending":
			result.TrendingStories = stories[:min(10, len(stories))]
		default:
			return cachedEdition{}, ErrContractMismatch
		}
		if r.err != nil {
			return cachedEdition{}, r.err
		}
	}
	result.PublicationPanels = result.PublicationPanels[:min(6, len(result.PublicationPanels))]
	result.StoryRails = result.StoryRails[:min(3, len(result.StoryRails))]
	moreRows, err := s.query(ctx, `SELECT EXISTS(SELECT 1 FROM wire_serving.ranked_items WHERE generation_id=$1::uuid AND position>=$2)`, g.id, ordinal)
	if err != nil {
		return cachedEdition{}, err
	}
	if len(moreRows) != 1 {
		return cachedEdition{}, ErrContractMismatch
	}
	proof.HasMore = moreRows[0].Bool(0)
	if moreRows[0].err != nil {
		return cachedEdition{}, moreRows[0].err
	}
	if proof.HasMore {
		cursor := strconv.Itoa(ordinal)
		result.Cursor = &cursor
	}
	accounts, err := s.talkedAccounts(ctx, g.id)
	if err != nil {
		return cachedEdition{}, err
	}
	for _, a := range accounts {
		proof.Accounts = append(proof.Accounts, a.DID)
	}
	if len(accounts) >= 4 {
		result.TalkedAboutAccounts = accounts
	}
	return cachedEdition{Edition{Edition: result, SourceActorKeysByItemID: actors}, proof}, nil
}
func validReason(reason wirecore.ReasonCode) bool {
	switch reason {
	case wirecore.BreakingStory, wirecore.FreshPublication, wirecore.Resurfacing, wirecore.SharedAcrossCommunities, wirecore.WidelyDiscussed:
		return true
	}
	return false
}
func (s *PostgreSQLStore) talkedAccounts(ctx context.Context, id string) ([]wirecore.TalkedAboutAccount, error) {
	rows, err := s.query(ctx, `SELECT position,subject_did,handle,display_name,avatar_url,description FROM wire_serving.edition_talked_accounts WHERE generation_id=$1::uuid ORDER BY position LIMIT 10`, id)
	if err != nil {
		return nil, err
	}
	result := []wirecore.TalkedAboutAccount{}
	for _, r := range rows {
		result = append(result, wirecore.TalkedAboutAccount{DID: r.String(1), Handle: r.OptionalString(2), DisplayName: r.OptionalString(3), AvatarURL: r.OptionalString(4), Description: r.OptionalString(5)})
		if r.err != nil {
			return nil, r.err
		}
	}
	return result, nil
}
func (s *PostgreSQLStore) fallbackEdition(ctx context.Context, q EditionQuery, now time.Time) (Edition, error) {
	limit := 50
	if q.FallbackLimit != nil {
		limit = *q.FallbackLimit
	}
	page, err := s.fallback(ctx, q.Language, min(5000, max(1, limit)), now)
	if err != nil {
		return Edition{}, err
	}
	actors := map[string]string{}
	items := []wirecore.FeedItem{}
	for i, r := range page.Rows {
		if r.SourceActorKey != nil {
			if _, ok := actors[r.Item.ItemID]; !ok {
				actors[r.Item.ItemID] = *r.SourceActorKey
			}
		}
		if i < 50 {
			items = append(items, r.Item)
		}
	}
	value := wirecore.AssembleEdition(page.GenerationID, page.GeneratedAt, page.Language, nil, page.Source, page.Degraded, items, nil)
	rows, err := s.query(ctx, `SELECT generation.generation_id FROM wire_serving.edition_generations generation WHERE generation.language_bucket=$1 AND EXISTS(SELECT 1 FROM wire_serving.edition_talked_accounts account WHERE account.generation_id=generation.generation_id) ORDER BY generation.generated_at DESC,generation.generation_id DESC LIMIT 1`, q.Language)
	if err != nil {
		return Edition{}, err
	}
	if len(rows) > 0 {
		accounts, e := s.talkedAccounts(ctx, rows[0].String(0))
		if e != nil {
			return Edition{}, e
		}
		if rows[0].err != nil {
			return Edition{}, rows[0].err
		}
		if len(accounts) >= 4 {
			value.TalkedAboutAccounts = accounts
		}
	}
	result := Edition{Edition: value, SourceActorKeysByItemID: actors}
	if q.FallbackLimit != nil {
		result.FallbackRows = page.Rows
	}
	return result, nil
}
