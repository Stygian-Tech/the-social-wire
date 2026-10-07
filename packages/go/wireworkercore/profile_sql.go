package wireworkercore

const profileClaimSQL = `WITH eligible AS (
        SELECT mention.subject_did
        FROM wire_item_mentions mention
        JOIN wire_items item ON item.canonical_key = mention.canonical_key
        WHERE mention.expires_at > $1
          AND item.eligible = TRUE AND item.expires_at > $1
          AND NOT EXISTS (
            SELECT 1 FROM wire_labels label
            WHERE label.canonical_key = item.canonical_key
              AND label.expires_at > $1
              AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
          )
        GROUP BY mention.subject_did
        HAVING COUNT(DISTINCT mention.canonical_key) >= 2
           AND COUNT(DISTINCT mention.speaker_key_hash) >= 3
      ), seeded AS (
        INSERT INTO wire_talked_accounts
          (subject_did, status, retry_after, failure_count)
        SELECT subject_did, 'pending', $1, 0 FROM eligible
        ON CONFLICT (subject_did) DO NOTHING
      ), due AS (
        SELECT profile.subject_did
        FROM wire_talked_accounts profile
        JOIN eligible ON eligible.subject_did = profile.subject_did
        WHERE COALESCE(profile.retry_after, profile.expires_at, $1) <= $1
        ORDER BY COALESCE(profile.expires_at, '-infinity'::timestamptz), profile.subject_did
        FOR UPDATE OF profile SKIP LOCKED
        LIMIT $2
      )
      UPDATE wire_talked_accounts profile
      SET status = 'pending', retry_after = $3
      FROM due
      WHERE profile.subject_did = due.subject_did
      RETURNING profile.subject_did`

const profileStoreSQL = `INSERT INTO wire_talked_accounts
        (subject_did, handle, display_name, avatar_url, description,
         status, fetched_at, expires_at, retry_after, failure_count)
      VALUES
        ($1, $2, $3, $4,
         $5, 'fresh', $6, $7,
         $7, 0)
      ON CONFLICT (subject_did) DO UPDATE SET
        handle = EXCLUDED.handle, display_name = EXCLUDED.display_name,
        avatar_url = EXCLUDED.avatar_url, description = EXCLUDED.description,
        status = 'fresh', fetched_at = EXCLUDED.fetched_at,
        expires_at = EXCLUDED.expires_at, retry_after = EXCLUDED.retry_after,
        failure_count = 0`

const profileFailureSQL = `UPDATE wire_talked_accounts
      SET status = CASE WHEN expires_at > $1 THEN 'fresh' ELSE 'failed' END,
          retry_after = $2,
          failure_count = failure_count + 1
      WHERE subject_did = $3`
