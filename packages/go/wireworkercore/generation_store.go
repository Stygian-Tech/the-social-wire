package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

var ErrMissingAuthority = errors.New("active generation publication requires role authority")

type moduleRecord struct {
	ModuleKey              string  `json:"module_key"`
	ModuleKind             string  `json:"module_kind"`
	Title                  *string `json:"title"`
	Position               int     `json:"position"`
	ReasonCode             *string `json:"reason_code"`
	PublicationKey         *string `json:"publication_key"`
	PublicationName        *string `json:"publication_name"`
	PublicationDomain      *string `json:"publication_domain"`
	PublicationHomepageURL *string `json:"publication_homepage_url"`
	PublicationIconURL     *string `json:"publication_icon_url"`
}
type moduleItemRecord struct {
	ModuleKey    string `json:"module_key"`
	Position     int    `json:"position"`
	CanonicalKey string `json:"canonical_key"`
}

func jsonString(value any) (string, error) {
	data, err := json.Marshal(value)
	return string(data), err
}
func pointer(value string) *string { return &value }
func (s *PostgresGenerationStore) Commit(ctx context.Context, g GenerationCommit) error {
	if g.Activate && s.Authority == nil {
		return ErrMissingAuthority
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	diagnostics, err := jsonString(g.Result.Diagnostics)
	if err != nil {
		return err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	exec := func(query string, args ...any) error { _, err := tx.ExecContext(ctx, query, args...); return err }
	if err := exec(`INSERT INTO wire_feed_state(feed_key,language_bucket,active_generation_id,updated_at) VALUES($1,$2,NULL,$3) ON CONFLICT(feed_key,language_bucket) DO NOTHING`, g.FeedKey, g.LanguageBucket, g.GeneratedAt); err != nil {
		return err
	}
	var active sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT active_generation_id FROM wire_feed_state WHERE feed_key=$1 AND language_bucket=$2 FOR UPDATE`, g.FeedKey, g.LanguageBucket).Scan(&active); err != nil {
		return err
	}
	if err := exec(`INSERT INTO wire_rank_generations(generation_id,feed_key,language_bucket,status,is_active,config_version,generated_at,committed_at,expires_at,candidate_count,ranked_count,diagnostics) VALUES($1,$2,$3,'building',FALSE,$4,$5,NULL,$6,$7,$8,$9::jsonb)`, g.GenerationID, g.FeedKey, g.LanguageBucket, g.ConfigVersion, g.GeneratedAt, g.ExpiresAt, g.Result.Diagnostics.CandidateCount, len(g.Result.Items), diagnostics); err != nil {
		return err
	}
	type rankedRecord struct {
		Position     int                   `json:"position"`
		CanonicalKey string                `json:"canonical_key"`
		Score        float64               `json:"score"`
		Reasons      []wirecore.ReasonCode `json:"reasons"`
	}
	ranks := make([]rankedRecord, len(g.Result.Items))
	for i, item := range g.Result.Items {
		ranks[i] = rankedRecord{i, item.Candidate.CanonicalKey, item.Score, item.ReasonCodes}
	}
	rankedJSON, err := jsonString(ranks)
	if err != nil {
		return err
	}
	if err := exec(`INSERT INTO wire_ranked_items(generation_id,position,canonical_key,score,reason_codes,diversity_metadata) SELECT $1,position,canonical_key,score,reasons,'{}'::jsonb FROM jsonb_to_recordset($2::jsonb) AS ranked(position integer,canonical_key text,score double precision,reasons jsonb)`, g.GenerationID, rankedJSON); err != nil {
		return err
	}
	items, err := loadEditionItems(ctx, tx, g.GenerationID)
	if err != nil {
		return err
	}
	accounts, err := loadEditionAccounts(ctx, tx, g.GenerationID, g.GeneratedAt)
	if err != nil {
		return err
	}
	edition := wirecore.AssembleEdition(g.GenerationID, g.GeneratedAt, g.LanguageBucket, nil, "ranked", false, items, accounts)
	topics, reasons := map[string][]string{}, map[string][]wirecore.ReasonCode{}
	for _, item := range g.Result.Items {
		topics[item.Candidate.CanonicalKey] = item.Candidate.TopicKeys
		reasons[item.Candidate.CanonicalKey] = item.ReasonCodes
	}
	outside := wirecore.DownrankAmericanPolitics(items, func(item wirecore.FeedItem) []string { return topics[item.ItemID] }, func(item wirecore.FeedItem) []wirecore.ReasonCode { return reasons[item.ItemID] })
	outsideEdition := wirecore.AssembleEdition(g.GenerationID, g.GeneratedAt, g.LanguageBucket, nil, "ranked", false, outside, accounts)
	if err := exec(`INSERT INTO wire_edition_generations(generation_id,algorithm_version,language_bucket,continuation_ordinal,materialized_at) VALUES($1,$2,$3,$4,$5)`, g.GenerationID, edition.AlgorithmVersion, g.LanguageBucket, min(50, len(g.Result.Items)), g.GeneratedAt); err != nil {
		return err
	}
	modules, moduleItems := []moduleRecord{}, []moduleItemRecord{}
	appendEdition := func(value wirecore.Edition, prefix string, position int) {
		appendModule := func(key, kind, title string, reason *string, publication *wirecore.EditionPublication, stories []wirecore.FeedItem) {
			if len(stories) == 0 {
				return
			}
			key = prefix + key
			m := moduleRecord{ModuleKey: key, ModuleKind: kind, Title: pointer(title), Position: position, ReasonCode: reason}
			if publication != nil {
				m.PublicationKey = pointer(publication.Key)
				m.PublicationName = pointer(publication.Name)
				m.PublicationDomain = pointer(publication.Domain)
				m.PublicationHomepageURL = publication.HomepageURL
				m.PublicationIconURL = publication.IconURL
			}
			modules = append(modules, m)
			for i, story := range stories {
				moduleItems = append(moduleItems, moduleItemRecord{key, i, story.ItemID})
			}
			position++
		}
		appendModule("top-stories", "top_stories", "Top Stories", nil, nil, value.LeadStories)
		for i, panel := range value.PublicationPanels {
			appendModule("publication-"+strconv.Itoa(i), "publication_spotlight", panel.Publication.Name, nil, &panel.Publication, panel.Stories)
		}
		for _, rail := range value.StoryRails {
			appendModule(rail.ID, "story_rail", rail.Title, pointer(string(rail.Reason)), nil, rail.Stories)
		}
		appendModule("general", "general", "More Across the Social Web", nil, nil, value.GeneralStories)
		appendModule("trending", "trending", "Trending", nil, nil, value.TrendingStories)
	}
	appendEdition(edition, "", 0)
	appendEdition(outsideEdition, "outside-us:", 1000)
	moduleJSON, err := jsonString(modules)
	if err != nil {
		return err
	}
	moduleItemsJSON, err := jsonString(moduleItems)
	if err != nil {
		return err
	}
	if err := exec(`INSERT INTO wire_edition_modules(generation_id,module_key,module_kind,title,position,reason_code,publication_key,publication_name,publication_domain,publication_homepage_url,publication_icon_url) SELECT $1,module_key,module_kind,title,position,reason_code,publication_key,publication_name,publication_domain,publication_homepage_url,publication_icon_url FROM jsonb_to_recordset($2::jsonb) AS module(module_key text,module_kind text,title text,position integer,reason_code text,publication_key text,publication_name text,publication_domain text,publication_homepage_url text,publication_icon_url text)`, g.GenerationID, moduleJSON); err != nil {
		return err
	}
	if err := exec(`INSERT INTO wire_edition_module_items(generation_id,module_key,position,canonical_key) SELECT $1,module_key,position,canonical_key FROM jsonb_to_recordset($2::jsonb) AS item(module_key text,position integer,canonical_key text)`, g.GenerationID, moduleItemsJSON); err != nil {
		return err
	}
	accountIDs := make([]struct {
		Position int    `json:"position"`
		DID      string `json:"did"`
	}, len(edition.TalkedAboutAccounts))
	for i, a := range edition.TalkedAboutAccounts {
		accountIDs[i].Position = i
		accountIDs[i].DID = a.DID
	}
	accountsJSON, err := jsonString(accountIDs)
	if err != nil {
		return err
	}
	if err := exec(`INSERT INTO wire_edition_talked_accounts(generation_id,position,subject_did) SELECT $1,position,did FROM jsonb_to_recordset($2::jsonb) AS account(position integer,did text)`, g.GenerationID, accountsJSON); err != nil {
		return err
	}
	// Validate ownership only after building, inside the publication transaction.
	if s.Authority != nil {
		if err := operationscore.LockRoleLeaseFence(ctx, tx, *s.Authority, false); err != nil {
			return err
		}
	}
	if g.Activate {
		if err := exec(`UPDATE wire_rank_generations SET status='superseded',is_active=FALSE WHERE feed_key=$1 AND language_bucket=$2 AND is_active=TRUE`, g.FeedKey, g.LanguageBucket); err != nil {
			return err
		}
		if err := exec(`UPDATE wire_rank_generations SET status='committed',is_active=TRUE,committed_at=$2 WHERE generation_id=$1`, g.GenerationID, g.GeneratedAt); err != nil {
			return err
		}
		if err := exec(`UPDATE wire_feed_state SET active_generation_id=$3,updated_at=$4 WHERE feed_key=$1 AND language_bucket=$2`, g.FeedKey, g.LanguageBucket, g.GenerationID, g.GeneratedAt); err != nil {
			return err
		}
	} else {
		if err := exec(`UPDATE wire_rank_generations SET status='shadow',committed_at=$2 WHERE generation_id=$1`, g.GenerationID, g.GeneratedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func loadEditionItems(ctx context.Context, tx *sql.Tx, generation string) ([]wirecore.FeedItem, error) {
	rows, err := tx.QueryContext(ctx, `SELECT item.canonical_key,item.canonical_url,item.representative_uri,item.title,item.summary,item.published_at,item.thumbnail_url,item.source_name,item.source_domain,item.publication_id,item.author_name,item.provenance::text,ranked.reason_codes::text,COALESCE(NULLIF(item.publication_id,''),item.source_domain),item.publication_homepage_url,item.publication_icon_url FROM wire_ranked_items ranked JOIN wire_items item ON item.canonical_key=ranked.canonical_key WHERE ranked.generation_id=$1 AND ranked.position<50 ORDER BY ranked.position`, generation)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []wirecore.FeedItem{}
	for rows.Next() {
		var item wirecore.FeedItem
		var provenance, reasons string
		if err := rows.Scan(&item.ItemID, &item.CanonicalURL, &item.RepresentativeURI, &item.Title, &item.Summary, &item.PublishedAt, &item.ThumbnailURL, &item.Source.Name, &item.Source.Domain, &item.Source.Publication, &item.Source.Author, &provenance, &reasons, &item.Source.PublicationKey, &item.Source.HomepageURL, &item.Source.IconURL); err != nil {
			return nil, err
		}
		item.Provenance = []string{}
		item.Reasons = []wirecore.ReasonCode{}
		if err := json.Unmarshal([]byte(provenance), &item.Provenance); err != nil {
			item.Provenance = []string{}
		}
		if err := json.Unmarshal([]byte(reasons), &item.Reasons); err != nil {
			item.Reasons = []wirecore.ReasonCode{}
		}
		item.Provenance = item.Provenance[:min(8, len(item.Provenance))]
		item.Reasons = item.Reasons[:min(2, len(item.Reasons))]
		result = append(result, item)
	}
	return result, rows.Err()
}
func loadEditionAccounts(ctx context.Context, tx *sql.Tx, generation string, at time.Time) ([]wirecore.TalkedAboutAccountCandidate, error) {
	rows, err := tx.QueryContext(ctx, `SELECT mentions.subject_did,profile.handle,profile.display_name,profile.avatar_url,profile.description,COUNT(DISTINCT mentions.canonical_key)::bigint,COUNT(DISTINCT mentions.speaker_key_hash)::bigint,MIN(ranked.position),MAX(mentions.occurred_at) FROM wire_item_mentions mentions JOIN wire_talked_accounts profile ON profile.subject_did=mentions.subject_did JOIN wire_ranked_items ranked ON ranked.generation_id=$1 AND ranked.canonical_key=mentions.canonical_key WHERE mentions.expires_at>$2 AND profile.status='fresh' AND profile.expires_at>$2 AND ranked.position<50 GROUP BY mentions.subject_did,profile.handle,profile.display_name,profile.avatar_url,profile.description HAVING COUNT(DISTINCT mentions.canonical_key)>=2 AND COUNT(DISTINCT mentions.speaker_key_hash)>=3 ORDER BY COUNT(DISTINCT mentions.canonical_key) DESC,COUNT(DISTINCT mentions.speaker_key_hash) DESC,MIN(ranked.position),MAX(mentions.occurred_at) DESC,mentions.subject_did LIMIT 10`, generation, at)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []wirecore.TalkedAboutAccountCandidate{}
	for rows.Next() {
		var c wirecore.TalkedAboutAccountCandidate
		if err := rows.Scan(&c.Account.DID, &c.Account.Handle, &c.Account.DisplayName, &c.Account.AvatarURL, &c.Account.Description, &c.DistinctStoryCount, &c.DistinctSpeakerCount, &c.BestStoryRank, &c.LatestMentionAt); err != nil {
			return nil, err
		}
		result = append(result, c)
	}
	return result, rows.Err()
}
func (s *PostgresGenerationStore) RecordCycleDuration(ctx context.Context, milliseconds float64, generation string) error {
	if math.IsNaN(milliseconds) || math.IsInf(milliseconds, 0) || milliseconds < 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	_, err := s.DB.ExecContext(ctx, `UPDATE wire_rank_generations SET diagnostics=diagnostics||jsonb_build_object('cycleDurationMilliseconds',$2::double precision) WHERE generation_id=$1 AND status IN('committed','shadow','superseded')`, generation, milliseconds)
	return err
}
