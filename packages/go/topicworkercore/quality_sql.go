package topicworkercore

// Canonical bounded topic admission SQL, shared with the reference workers.
const financeQuality = `item.eligible=TRUE AND item.expires_at>$1
    AND item.target_kind IN ('external_article','standard_site_document')
    AND item.commercial_class<>'probable_ad' AND item.source_confidence>=0.75
    AND length(btrim(item.title))>=12 AND item.canonical_url ~* '^https?://'
    AND COALESCE(item.published_at,item.first_seen_at)>=$1-interval '30 days'
    AND (item.provenance ? 'standard_site' OR EXISTS (
      SELECT 1 FROM wire_link_metadata_cache metadata WHERE metadata.canonical_key=item.canonical_key
        AND metadata.source='open_graph' AND metadata.status IN ('fresh','stale') AND metadata.stale_until>$1
        AND num_nonnulls(metadata.title,metadata.description,metadata.image_url,metadata.site_name,
          metadata.author_name,metadata.published_at::text,metadata.icon_url)>=2 OFFSET 0))
    AND concat_ws(' ',item.title,item.summary) ~* '(bitcoin|crypto|commodity|nasdaq|dividend|earnings|stock|shares|investor|market|economy|inflation|interest rate|central bank|gdp|unemployment|employment report|jobs report|consumer prices|economic growth|recession|tariff|trade deficit|trade surplus|government budget|bond|fiscal|merger|acquisition|revenue|filing|regulation|announces|launches|semiconductor|software|technology|pharmaceutical|healthcare|biotech|bank|insurance|financial|oil|energy|natural gas|mining|metals|chemicals|manufacturing|aerospace|industrial|retail|consumer|automotive|telecom|media|utilities|electric utility|real estate|housing|industry|sector|company|business|sales|production|supply|demand|investment|exports|imports|regulatory|manufacturers|firms|ceo|chief executive|leadership)'
    AND NOT EXISTS (SELECT 1 FROM wire_labels label WHERE label.canonical_key=item.canonical_key
      AND label.expires_at>$1 AND label.label_key IN ('moderation','visibility')
      AND label.label_value IN ('block','exclude','adult','graphic','spam'))`
const financeCandidatesSQL = `WITH analysis_pool AS MATERIALIZED (
        SELECT analysis.* FROM finance_article_analysis analysis JOIN wire_items candidate
          ON candidate.canonical_key=analysis.canonical_key
        WHERE analysis.expires_at>$1 AND analysis.catalog_revision=$3 AND analysis.resolver_version=$4
          AND analysis.payload->>'eligible'='true' AND candidate.language_code=$2
        ORDER BY analysis.analyzed_at DESC,analysis.canonical_key LIMIT 3000
      )
      SELECT item.canonical_key,item.canonical_url,item.representative_uri,item.title,item.summary,
        item.published_at,item.thumbnail_url,item.source_name,item.source_domain,item.publication_id,
        item.author_name,item.provenance::text,analysis.payload::text,item.first_seen_at,item.source_confidence,
        item.provenance ? 'standard_site',item.commercial_class,item.commercial_score,
        COALESCE(rollup.baseline_shares_1h,0),COALESCE(rollup.baseline_shares_24h,0),
        COALESCE(rollup.baseline_recommendations_24h,0),COALESCE(rollup.baseline_signals_7d,0),
        COALESCE(rollup.communities_24h,0),COALESCE(rollup.baseline_distinct_likers_24h,0),
        COALESCE(rollup.baseline_likes_1h,0),COALESCE(rollup.baseline_likes_24h,0),
        COALESCE(rollup.distinct_reposters_24h,0),COALESCE(rollup.reposts_1h,0),
        COALESCE(rollup.reposts_24h,0),COALESCE(rollup.positive_feedback_24h,0),
        COALESCE(rollup.negative_feedback_24h,0)
      FROM analysis_pool analysis JOIN wire_items item ON analysis.canonical_key=item.canonical_key
      LEFT JOIN wire_signal_rollups rollup ON rollup.canonical_key=item.canonical_key
      WHERE item.eligible=TRUE AND item.expires_at>$1
    AND item.target_kind IN ('external_article','standard_site_document')
    AND item.commercial_class<>'probable_ad' AND item.source_confidence>=0.75
    AND length(btrim(item.title))>=12 AND item.canonical_url ~* '^https?://'
    AND COALESCE(item.published_at,item.first_seen_at)>=$1-interval '30 days'
    AND (item.provenance ? 'standard_site' OR EXISTS (
      SELECT 1 FROM wire_link_metadata_cache metadata WHERE metadata.canonical_key=item.canonical_key
        AND metadata.source='open_graph' AND metadata.status IN ('fresh','stale') AND metadata.stale_until>$1
        AND num_nonnulls(metadata.title,metadata.description,metadata.image_url,metadata.site_name,
          metadata.author_name,metadata.published_at::text,metadata.icon_url)>=2 OFFSET 0))
    AND concat_ws(' ',item.title,item.summary) ~* '(bitcoin|crypto|commodity|nasdaq|dividend|earnings|stock|shares|investor|market|economy|inflation|interest rate|central bank|gdp|unemployment|employment report|jobs report|consumer prices|economic growth|recession|tariff|trade deficit|trade surplus|government budget|bond|fiscal|merger|acquisition|revenue|filing|regulation|announces|launches|semiconductor|software|technology|pharmaceutical|healthcare|biotech|bank|insurance|financial|oil|energy|natural gas|mining|metals|chemicals|manufacturing|aerospace|industrial|retail|consumer|automotive|telecom|media|utilities|electric utility|real estate|housing|industry|sector|company|business|sales|production|supply|demand|investment|exports|imports|regulatory|manufacturers|firms|ceo|chief executive|leadership)'
    AND NOT EXISTS (SELECT 1 FROM wire_labels label WHERE label.canonical_key=item.canonical_key
      AND label.expires_at>$1 AND label.label_key IN ('moderation','visibility')
      AND label.label_value IN ('block','exclude','adult','graphic','spam')) AND item.language_code=$2
        AND analysis.source_fingerprint=md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)
        AND analysis.catalog_revision=$3 AND analysis.resolver_version=$4 AND analysis.expires_at>$1
      ORDER BY item.updated_at DESC,item.canonical_key LIMIT 3000`
const sportsQuality = `item.eligible=TRUE AND item.expires_at>$1
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
      AND label.label_value IN ('block','exclude','adult','graphic','spam'))`
const sportsCandidatesSQL = `WITH prior_generation AS MATERIALIZED (
        SELECT payload FROM sports_generations
        WHERE language=$2 AND expires_at>$1
        ORDER BY jsonb_array_length(payload) DESC,generated_at DESC LIMIT 1
      ), prior_keys AS MATERIALIZED (
        SELECT candidate->'item'->>'itemId' AS canonical_key
        FROM prior_generation CROSS JOIN LATERAL jsonb_array_elements(payload) candidate LIMIT 3000
      ), recent_keys AS MATERIALIZED (
        SELECT canonical_key FROM wire_items
        WHERE eligible=TRUE AND target_kind IN ('external_article','standard_site_document')
          AND commercial_class<>'probable_ad' AND source_confidence>=0.75
        ORDER BY updated_at DESC,canonical_key LIMIT 1000
      ), candidate_keys AS MATERIALIZED (
        SELECT canonical_key FROM prior_keys UNION SELECT canonical_key FROM recent_keys
      ), analysis_pool AS MATERIALIZED (
        SELECT analysis.* FROM candidate_keys keys
        JOIN sports_article_analysis analysis ON analysis.canonical_key=keys.canonical_key
        JOIN wire_items candidate ON candidate.canonical_key=analysis.canonical_key
        WHERE analysis.expires_at>$1 AND analysis.payload->>'eligible'='true' AND candidate.language_code=$2
        ORDER BY analysis.analyzed_at DESC,analysis.canonical_key LIMIT 3000
      )
      SELECT item.canonical_key,item.canonical_url,item.representative_uri,item.title,item.summary,
        item.published_at,item.thumbnail_url,item.source_name,item.source_domain,item.publication_id,
        item.author_name,item.provenance::text,analysis.payload::text,item.first_seen_at,item.source_confidence,
        item.provenance ? 'standard_site',item.commercial_class,item.commercial_score,
        COALESCE(rollup.baseline_shares_1h,0),COALESCE(rollup.baseline_shares_24h,0),
        COALESCE(rollup.baseline_recommendations_24h,0),COALESCE(rollup.baseline_signals_7d,0),
        COALESCE(rollup.communities_24h,0),COALESCE(rollup.baseline_distinct_likers_24h,0),
        COALESCE(rollup.baseline_likes_1h,0),COALESCE(rollup.baseline_likes_24h,0),
        COALESCE(rollup.distinct_reposters_24h,0),COALESCE(rollup.reposts_1h,0),
        COALESCE(rollup.reposts_24h,0),COALESCE(rollup.positive_feedback_24h,0),
        COALESCE(rollup.negative_feedback_24h,0),
        analysis.catalog_revision=$3 AND analysis.resolver_version=$4
      FROM analysis_pool analysis JOIN wire_items item ON analysis.canonical_key=item.canonical_key
      LEFT JOIN wire_signal_rollups rollup ON rollup.canonical_key=item.canonical_key
      WHERE item.eligible=TRUE AND item.expires_at>$1
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
      AND label.label_value IN ('block','exclude','adult','graphic','spam')) AND item.language_code=$2
        AND analysis.source_fingerprint=md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)
        AND analysis.expires_at>$1
      ORDER BY item.updated_at DESC,item.canonical_key LIMIT 3000`
