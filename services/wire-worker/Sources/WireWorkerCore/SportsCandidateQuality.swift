import Foundation
import PostgresNIO
import WireCore

/// Sports's topic admission precedes the shared score/diversity framework.
/// General Wire social thresholds and activation floors remain unchanged.
enum SportsCandidateQuality {
  static let predicate = """
    item.eligible=TRUE AND item.expires_at>$1
    AND item.target_kind IN ('external_article','standard_site_document')
    AND item.commercial_class<>'probable_ad' AND item.source_confidence>=0.75
    AND length(btrim(item.title))>=12 AND item.canonical_url ~* '^https?://'
    AND COALESCE(item.published_at,item.first_seen_at)>=$1-interval '30 days'
    AND (item.provenance ? 'standard_site' OR EXISTS (
      SELECT 1 FROM wire_link_metadata_cache metadata WHERE metadata.canonical_key=item.canonical_key
        AND metadata.source='open_graph' AND metadata.status IN ('fresh','stale') AND metadata.stale_until>$1
        AND num_nonnulls(metadata.title,metadata.description,metadata.image_url,metadata.site_name,
          metadata.author_name,metadata.published_at::text,metadata.icon_url)>=2 OFFSET 0))
    AND NOT EXISTS (SELECT 1 FROM wire_labels label WHERE label.canonical_key=item.canonical_key
      AND label.expires_at>$1 AND label.label_key IN ('moderation','visibility')
      AND label.label_value IN ('block','exclude','adult','graphic','spam'))
    """

  static var ranking: WireRankingConfig {
    WireRankingConfig(minimumHighIntentActors: 0,
      minimumRecommendations: 0, standardSiteMinimumHighIntentActors: 0,
      backfillMinimumHighIntentActors: 0, backfillMinimumRecommendations: 0,
      minimumSourceConfidence: 0.75)
  }
}
