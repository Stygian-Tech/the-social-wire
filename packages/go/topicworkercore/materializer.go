package topicworkercore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func identifier() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}
func (w *Worker) materializeFinance(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	catalog, err := w.financeCatalog(ctx)
	if err != nil || catalog == nil {
		return err
	}
	rows, err := w.DB.QueryContext(ctx, `WITH analysis_pool AS MATERIALIZED (SELECT canonical_key FROM finance_article_analysis WHERE expires_at>$1 AND payload->>'eligible'='true' ORDER BY analyzed_at DESC,canonical_key LIMIT 3000) SELECT item.language_code FROM analysis_pool analysis JOIN wire_items item ON analysis.canonical_key=item.canonical_key WHERE `+financeQuality+` GROUP BY item.language_code ORDER BY count(*) DESC,item.language_code LIMIT 13`, at)
	if err != nil {
		return err
	}
	languages, err := collectLanguages(rows)
	if err != nil {
		return err
	}
	for _, language := range languages {
		if err := w.materialize(ctx, authority, at, "finance", language, catalog.Revision, catalog, nil); err != nil {
			return err
		}
	}
	return nil
}
func (w *Worker) materializeSports(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	catalog, err := w.sportsCatalog(ctx)
	if err != nil || catalog == nil {
		return err
	}
	rows, err := w.DB.QueryContext(ctx, `WITH recent_keys AS MATERIALIZED(SELECT canonical_key FROM wire_items WHERE eligible=TRUE AND target_kind IN ('external_article','standard_site_document') AND commercial_class<>'probable_ad' AND source_confidence>=0.75 ORDER BY updated_at DESC,canonical_key LIMIT 1000),recent_languages AS(SELECT item.language_code AS language,count(*) AS weight FROM recent_keys keys JOIN wire_items item ON item.canonical_key=keys.canonical_key JOIN sports_article_analysis analysis ON analysis.canonical_key=item.canonical_key WHERE analysis.expires_at>$1 AND analysis.payload->>'eligible'='true' AND `+sportsQuality+` GROUP BY item.language_code),retained_languages AS(SELECT language,max(jsonb_array_length(payload)) AS weight FROM sports_generations WHERE expires_at>$1 GROUP BY language) SELECT language FROM(SELECT language,weight FROM recent_languages UNION ALL SELECT language,weight FROM retained_languages) available GROUP BY language ORDER BY sum(weight) DESC,language LIMIT 13`, at)
	if err != nil {
		return err
	}
	languages, err := collectLanguages(rows)
	if err != nil {
		return err
	}
	for _, language := range languages {
		if err := w.materialize(ctx, authority, at, "sports", language, catalog.Version, nil, catalog); err != nil {
			return err
		}
	}
	return nil
}
func collectLanguages(rows *sql.Rows) ([]string, error) {
	defer rows.Close()
	result := []string{}
	for rows.Next() {
		var language string
		if err := rows.Scan(&language); err != nil {
			return nil, err
		}
		result = append(result, language)
	}
	return result, rows.Err()
}
func strptr(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	return &value.String
}
func timeptr(value sql.NullTime) *time.Time {
	if !value.Valid {
		return nil
	}
	return &value.Time
}
func boolptr(value bool) *bool { return &value }
func (w *Worker) materialize(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time, topic, language, revision string, finance *financeCatalog, sports *sportsSnapshot) error {
	query, resolver := financeCandidatesSQL, financecore.ResolverVersion
	if topic == "sports" {
		query, resolver = sportsCandidatesSQL, sportscore.ResolverVersion
	}
	rows, err := w.DB.QueryContext(ctx, query, at, language, revision, resolver)
	if err != nil {
		return err
	}
	defer rows.Close()
	stories := map[string]wirecore.FeedItem{}
	analyses := map[string]any{}
	candidates := []wirecore.Candidate{}
	var index *sportscore.EntityIndex
	if sports != nil {
		index = sportscore.NewEntityIndex(sports.Entities)
	}
	for rows.Next() {
		var key, url, title, sourceName, domain, provenance, analysisJSON, commercial string
		var representative, summary, thumbnail, publication, author sql.NullString
		var published sql.NullTime
		var firstSeen time.Time
		var confidence, commercialScore float64
		var standard, current bool
		var shares1h, shares24h, recommendations, signals7d, communities, distinctLikes, likes1h, likes24h, distinctReposts, reposts1h, reposts24h, positive, negative int
		values := []any{&key, &url, &representative, &title, &summary, &published, &thumbnail, &sourceName, &domain, &publication, &author, &provenance, &analysisJSON, &firstSeen, &confidence, &standard, &commercial, &commercialScore, &shares1h, &shares24h, &recommendations, &signals7d, &communities, &distinctLikes, &likes1h, &likes24h, &distinctReposts, &reposts1h, &reposts24h, &positive, &negative}
		if topic == "sports" {
			values = append(values, &current)
		}
		if err := rows.Scan(values...); err != nil {
			return err
		}
		var topics []string
		if topic == "finance" {
			var analysis financecore.ArticleAnalysis
			if err := json.Unmarshal([]byte(analysisJSON), &analysis); err != nil {
				return err
			}
			if !analysis.Eligible || (analysis.Materiality == "price-chatter" && shares24h < 3 && recommendations < 1) {
				continue
			}
			analyses[key] = analysis
			topics = append(append([]string{}, analysis.SectorIDs...), analysis.MacroTopics...)
		} else {
			var analysis sportscore.ArticleAnalysis
			if err := json.Unmarshal([]byte(analysisJSON), &analysis); err != nil {
				return err
			}
			current = current && analysis.ResolverVersion == sportscore.ResolverVersion
			for _, association := range analysis.Associations {
				current = current && association.ResolverVersion == sportscore.ResolverVersion
			}
			if !current {
				analysis = sportscore.AnalyzeIndex(title, summary.String, index)
			}
			if !analysis.Eligible || (analysis.Materiality == "routine-chatter" && shares24h < 3 && recommendations < 1) {
				continue
			}
			analyses[key] = analysis
			topics = append(append([]string{}, analysis.SportIDs...), analysis.CompetitionIDs...)
		}
		var origins []string
		if err := json.Unmarshal([]byte(provenance), &origins); err != nil {
			return err
		}
		story := wirecore.FeedItem{ItemID: key, CanonicalURL: url, RepresentativeURI: strptr(representative), Title: title, Summary: strptr(summary), PublishedAt: timeptr(published), ThumbnailURL: strptr(thumbnail), Source: wirecore.ItemSource{Name: sourceName, Domain: domain, Publication: strptr(publication), Author: strptr(author)}, Reasons: []wirecore.ReasonCode{}, Provenance: origins}
		stories[key] = story
		c := wirecore.NewCandidate(key, url, domain, firstSeen)
		c.RepresentativeURI = story.RepresentativeURI
		c.PublicationID = story.Source.Publication
		c.AuthorKey = story.Source.Author
		c.TopicKeys = topics
		c.PublishedAt = story.PublishedAt
		c.Signals7d = signals7d
		c.Communities24h = communities
		c.Recommendations24h = recommendations
		c.PositiveFeedback24h = positive
		c.NegativeFeedback24h = negative
		c.Shares1h = shares1h
		c.Shares24h = shares24h
		c.DistinctLikes24h = distinctLikes
		c.Likes1h = likes1h
		c.Likes24h = likes24h
		c.DistinctReposts24h = distinctReposts
		c.Reposts1h = reposts1h
		c.Reposts24h = reposts24h
		c.SourceConfidence = confidence
		c.IsStandardSite = boolptr(standard)
		c.HasUsableOpenGraphMetadata = boolptr(true)
		c.HasUsableThumbnail = boolptr(story.ThumbnailURL != nil)
		c.CommercialClass = wirecore.CommercialClass(commercial)
		if c.CommercialClass != wirecore.Normal && c.CommercialClass != wirecore.Limited {
			c.CommercialClass = wirecore.ProbableAd
		}
		c.CommercialScore = commercialScore
		candidates = append(candidates, c)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	config := wirecore.DefaultRankingConfig()
	config.MinimumHighIntentActors = 0
	config.MinimumRecommendations = 0
	config.StandardSiteMinimumHighIntentActors = 0
	config.BackfillMinimumHighIntentActors = 0
	config.BackfillMinimumRecommendations = 0
	config.MinimumSourceConfidence = .75
	ranked, err := wirecore.Rank(candidates, at, config)
	if err != nil {
		return err
	}
	payloadCandidates := []any{}
	for position, scored := range ranked.Items {
		key := scored.Candidate.CanonicalKey
		story := stories[key]
		if story.PublishedAt != nil {
			published := story.PublishedAt.Truncate(time.Second)
			story.PublishedAt = &published
		}
		if topic == "finance" {
			payloadCandidates = append(payloadCandidates, financecore.RankCandidate{Item: story, Analysis: analyses[key].(financecore.ArticleAnalysis), BaseScore: scored.Score, MajorGlobal: position < 20})
		} else {
			payloadCandidates = append(payloadCandidates, sportscore.RankCandidate{Item: story, Analysis: analyses[key].(sportscore.ArticleAnalysis), BaseScore: scored.Score, MajorGlobal: position < 20})
		}
	}
	if len(payloadCandidates) == 0 {
		return nil
	}
	payload, err := json.Marshal(payloadCandidates)
	if err != nil {
		return err
	}
	activate := mode(w.env, "FINANCE_FEED_MODE") == "api" || mode(w.env, "FINANCE_FEED_MODE") == "visible"
	if topic == "sports" {
		activate = mode(w.env, "SPORTS_FEED_MODE") == "api" || mode(w.env, "SPORTS_FEED_MODE") == "visible"
	}
	tx, err := w.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fence(ctx, tx, authority); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='15s'`); err != nil {
		return err
	}
	if activate {
		if _, err := tx.ExecContext(ctx, `UPDATE `+topic+`_generations SET is_active=FALSE WHERE language=$1 AND is_active=TRUE`, language); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO `+topic+`_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active) VALUES($1,$2,$3,$4,$5,$6,$7::jsonb,$8)`, identifier(), identifier(), language, topic+"-v1", at, at.Add(48*time.Hour), string(payload), activate); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM `+topic+`_generations WHERE generation_id IN(SELECT generation_id FROM `+topic+`_generations WHERE expires_at<=$1 ORDER BY expires_at LIMIT 100)`, at); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM `+topic+`_catalog_snapshots WHERE snapshot_id IN(SELECT snapshot_id FROM `+topic+`_catalog_snapshots WHERE is_active=FALSE AND generated_at<$1 ORDER BY generated_at LIMIT 20)`, at.Add(-7*24*time.Hour)); err != nil {
		return err
	}
	return tx.Commit()
}
