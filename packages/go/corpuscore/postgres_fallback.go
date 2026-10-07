package corpuscore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strconv"
	"time"
)

func (s *PostgreSQLStore) fallback(ctx context.Context, language string, limit int, now time.Time) (Page, error) {
	rows, err := s.query(ctx, `
      WITH candidate_keys AS MATERIALIZED (
        SELECT canonical_key, topic_keys, first_seen_at, source_confidence,
          target_kind, commercial_class, commercial_score, is_standard_site,
          has_usable_open_graph, has_usable_thumbnail,
          baseline_last_signal_at, baseline_distinct_actors_1h,
          baseline_distinct_actors_24h, baseline_distinct_actors_7d,
          baseline_signals_1h, baseline_signals_24h,
          baseline_signals_7d, communities_24h,
          primary_community_key_hash, baseline_recommendations_24h,
          positive_feedback_24h, negative_feedback_24h,
          baseline_shares_1h, baseline_shares_24h,
          baseline_distinct_likers_24h, baseline_likes_1h,
          baseline_likes_24h, distinct_reposters_24h,
          reposts_1h, reposts_24h,
          CASE WHEN baseline_shares_24h >= 5 OR baseline_recommendations_24h >= 2 THEN 0
            WHEN is_standard_site AND published_at >= $2
              AND baseline_shares_24h >= 1 THEN 1
            WHEN baseline_shares_24h >= 3 OR baseline_recommendations_24h >= 1 THEN 2
            ELSE 3 END AS priority
        FROM wire_serving.fallback_candidates
        WHERE ($1 = 'und' OR language_code = $1)
        ORDER BY priority, baseline_shares_24h DESC, baseline_recommendations_24h DESC,
          is_standard_site DESC, has_usable_thumbnail DESC, has_usable_open_graph DESC,
          baseline_signals_1h DESC, canonical_key
        LIMIT 5000
      )
      SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
        item.summary, item.published_at, item.thumbnail_url, item.source_name,
        item.source_domain, item.publication_id, item.author_name, item.provenance::text,
        item.author_key, selected.topic_keys::text, item.publication_key,
        item.publication_homepage_url, item.publication_icon_url,
        selected.first_seen_at, selected.baseline_last_signal_at, selected.source_confidence,
        selected.is_standard_site, selected.has_usable_open_graph, selected.has_usable_thumbnail,
        selected.target_kind, selected.commercial_class, selected.commercial_score,
        selected.baseline_distinct_actors_1h, selected.baseline_distinct_actors_24h,
        selected.baseline_distinct_actors_7d, selected.baseline_signals_1h,
        selected.baseline_signals_24h, selected.baseline_signals_7d,
        selected.communities_24h, selected.primary_community_key_hash,
        selected.baseline_recommendations_24h, selected.positive_feedback_24h,
        selected.negative_feedback_24h, selected.baseline_shares_1h, selected.baseline_shares_24h,
        selected.baseline_distinct_likers_24h, selected.baseline_likes_1h,
        selected.baseline_likes_24h, selected.distinct_reposters_24h,
        selected.reposts_1h, selected.reposts_24h
      FROM candidate_keys selected
      JOIN LATERAL (
        SELECT * FROM wire_serving.items
        WHERE canonical_key = selected.canonical_key
        LIMIT 1
      ) item ON TRUE
      ORDER BY selected.priority, selected.baseline_shares_24h DESC,
        selected.baseline_recommendations_24h DESC, selected.is_standard_site DESC,
        selected.has_usable_thumbnail DESC, selected.has_usable_open_graph DESC,
        selected.baseline_signals_1h DESC, selected.canonical_key
      `, language, now.Add(-72*time.Hour))
	if err != nil {
		return Page{}, err
	}
	items := map[string]wirecore.FeedItem{}
	candidates := []wirecore.Candidate{}
	for _, r := range rows {
		if err := ctx.Err(); err != nil {
			return Page{}, err
		}
		item := decodeItem(r, 0, "[]", 14)
		items[item.ItemID] = item
		topics := []string{}
		if json.Unmarshal([]byte(r.String(13)), &topics) != nil {
			topics = []string{}
		}
		standard, openGraph, thumbnail := r.Bool(20), r.Bool(21), r.Bool(22)
		kind := wirecore.TargetKind(r.String(23))
		switch kind {
		case wirecore.ExternalArticle, wirecore.StandardSiteDocument, wirecore.SocialPost, wirecore.ProfileOrFeed, wirecore.CommerceOrAd, wirecore.OperationalStatus, wirecore.Unsupported:
		default:
			kind = wirecore.Unsupported
		}
		commercial := wirecore.CommercialClass(r.String(24))
		if commercial != wirecore.Normal && commercial != wirecore.Limited {
			commercial = wirecore.ProbableAd
		}
		candidates = append(candidates, wirecore.Candidate{CanonicalKey: item.ItemID, CanonicalURL: item.CanonicalURL, RepresentativeURI: item.RepresentativeURI, SourceDomain: item.Source.Domain, PublicationID: item.Source.Publication, AuthorKey: r.OptionalString(12), TopicKeys: topics, PublishedAt: item.PublishedAt, FirstSeenAt: r.Time(17), LastSignalAt: r.OptionalTime(18), DistinctActors1h: r.Int(26), DistinctActors24h: r.Int(27), DistinctActors7d: r.Int(28), Signals1h: r.Int(29), Signals24h: r.Int(30), Signals7d: r.Int(31), Communities24h: r.Int(32), PrimaryCommunityKey: r.OptionalString(33), Recommendations24h: r.Int(34), PositiveFeedback24h: r.Int(35), NegativeFeedback24h: r.Int(36), Shares1h: r.Int(37), Shares24h: r.Int(38), DistinctLikes24h: r.Int(39), Likes1h: r.Int(40), Likes24h: r.Int(41), DistinctReposts24h: r.Int(42), Reposts1h: r.Int(43), Reposts24h: r.Int(44), SourceConfidence: r.Float(19), IsStandardSite: &standard, HasUsableOpenGraphMetadata: &openGraph, HasUsableThumbnail: &thumbnail, TargetKind: kind, CommercialClass: commercial, CommercialScore: r.Float(25)})
		if r.err != nil {
			return Page{}, r.err
		}
	}
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	ranked, err := wirecore.Rank(candidates, now, wirecore.DefaultRankingConfig())
	if err != nil {
		return Page{}, err
	}
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	result := []Row{}
	for _, rank := range ranked.Items[:min(limit, len(ranked.Items))] {
		item, ok := items[rank.Candidate.CanonicalKey]
		if !ok {
			continue
		}
		item.Reasons = rank.ReasonCodes[:min(2, len(rank.ReasonCodes))]
		result = append(result, Row{len(result), item, rank.Candidate.AuthorKey})
	}
	bucket := now.Unix() / 300
	return Page{"fallback-" + strconv.FormatInt(bucket, 10), time.Unix(bucket*300, 0).UTC(), language, "simplified_fallback", true, result, true}, nil
}
