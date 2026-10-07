package corpuscore

import (
	"context"
	"encoding/json"
	"strconv"
	"time"
)

func (s *PostgreSQLStore) CircleCandidates(ctx context.Context, q CandidateRequest, now time.Time) (CandidateResponse, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return CandidateResponse{}, err
	}
	gen, err := s.activeGeneration(ctx, q.Language, now)
	if err != nil {
		return CandidateResponse{}, err
	}
	rows, err := s.query(ctx, `
      WITH matched AS MATERIALIZED (
        SELECT *
        FROM wire_serving.circle_signal_facts
        WHERE actor_key_hash = ANY($1)
          AND occurred_at >= $2
          AND ($3 = 'und' OR language_code = $3)
      ), selected AS (
        SELECT canonical_key, COUNT(DISTINCT actor_key_hash) AS participant_count,
               MAX(occurred_at) AS latest_signal
        FROM matched
        GROUP BY canonical_key
        ORDER BY participant_count DESC, latest_signal DESC, canonical_key
        LIMIT $4
      )
      SELECT matched.canonical_key, canonical_url, representative_uri, title, summary,
             published_at, thumbnail_url, source_name, source_domain, publication_id,
             author_name, provenance::text, author_key, publication_key,
             publication_homepage_url, publication_icon_url, topic_keys::text,
             actor_key_hash, signal_kind,
             source_collection, source_action, source_uri, occurred_at
      FROM matched
      JOIN selected USING (canonical_key)
      ORDER BY selected.participant_count DESC, selected.latest_signal DESC,
               matched.canonical_key, matched.occurred_at DESC, matched.actor_key_hash
      `, q.ActorHashes, q.Since, q.Language, q.Limit)
	if err != nil {
		return CandidateResponse{}, err
	}
	stories := []CandidateStory{}
	indices := map[string]int{}
	for _, r := range rows {
		key := r.String(0)
		index, ok := indices[key]
		if !ok {
			index = len(stories)
			indices[key] = index
			topics := []string{}
			if json.Unmarshal([]byte(r.String(16)), &topics) != nil {
				topics = []string{}
			}
			stories = append(stories, CandidateStory{decodeItem(r, 0, "[]", 13), topics, []SignalFact{}})
		}
		kind := r.String(18)
		switch kind {
		case "recommendation", "share", "quote", "reply", "like", "repost", "publication":
		default:
			return CandidateResponse{}, ErrContractMismatch
		}
		stories[index].Facts = append(stories[index].Facts, SignalFact{r.String(17), kind, r.String(19), r.String(20), r.String(21), r.Time(22)})
		if r.err != nil {
			return CandidateResponse{}, r.err
		}
	}
	id := "circle-" + strconv.FormatInt(now.Unix()/300, 10)
	if gen != nil {
		id = gen.id
	}
	return CandidateResponse{id, now, q.Language, stories, len(stories) < q.Limit}, nil
}
