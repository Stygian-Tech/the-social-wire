package podcastcore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
)

func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

func NewClipID() (string, error) { return newUUID() }

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Store) Enqueue(ctx context.Context, viewer, episodeID *string, kind, key, payload string) (string, error) {
	if episodeID != nil && IsPrivateID(*episodeID) {
		return "", ErrInvalidRequest
	}
	id, err := newUUID()
	if err != nil {
		return "", err
	}
	var jobID string
	err = s.DB.QueryRowContext(ctx, `INSERT INTO podcast_jobs(id,viewer_did,episode_id,kind,dedupe_key,payload_json) VALUES($1::uuid,$2,$3,$4,$5,$6::jsonb) ON CONFLICT(dedupe_key) DO UPDATE SET dedupe_key=EXCLUDED.dedupe_key RETURNING id::text`, id, viewer, episodeID, kind, key, payload).Scan(&jobID)
	return jobID, err
}

type JobQuery struct {
	Viewer                                      string
	JobID, EpisodeID, Kind, ShowID, Key, ClipID *string
}

func (s *Store) Job(ctx context.Context, q JobQuery) (*string, error) {
	var raw string
	err := s.DB.QueryRowContext(ctx, `SELECT jsonb_build_object('id',id::text,'kind',kind,'status',status,'result',result_json,'error',error)::text FROM podcast_jobs WHERE (viewer_did=$1 OR (viewer_did IS NULL AND kind='silence') OR (viewer_did IS NULL AND kind='bridge' AND EXISTS(SELECT 1 FROM podcast_subscriptions s WHERE s.viewer_did=$1 AND s.show_id=podcast_jobs.payload_json->>'showId'))) AND ($2::text IS NULL OR id::text=$2) AND ($3::text IS NULL OR episode_id=$3) AND ($4::text IS NULL OR kind=$4) AND ($5::text IS NULL OR payload_json->>'showId'=$5) AND ($6::text IS NULL OR dedupe_key=$6) AND ($7::text IS NULL OR payload_json->>'clipId'=$7) ORDER BY created_at DESC LIMIT 1`, q.Viewer, q.JobID, q.EpisodeID, q.Kind, q.ShowID, q.Key, q.ClipID).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &raw, nil
}
func (s *Store) InvalidateAnalysis(ctx context.Context, id, fingerprint string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE podcast_jobs SET status='failed',result_json=NULL,error='Media Source Changed During Analysis',updated_at=now() WHERE id::text=$1 AND kind='silence' AND status='complete' AND result_json->>'sourceFingerprint' IS DISTINCT FROM $2::text`, id, fingerprint)
	return err
}
func (s *Store) Retry(ctx context.Context, viewer, id string) (bool, error) {
	job, err := s.Job(ctx, JobQuery{Viewer: viewer, JobID: &id})
	if err != nil || job == nil {
		return false, err
	}
	var retried string
	err = s.DB.QueryRowContext(ctx, `WITH retried AS (UPDATE podcast_jobs SET status='queued',available_at=now(),error=NULL,updated_at=now() WHERE id::text=$1 AND status='failed' AND attempts<5 AND kind IN ('bridge','silence','clip') RETURNING id,kind,payload_json),reset_clip AS (UPDATE podcast_clips SET clip_json=jsonb_set(clip_json-'error','{status}','"queued"'::jsonb),updated_at=now() FROM retried WHERE retried.kind='clip' AND podcast_clips.id::text=retried.payload_json->>'clipId' RETURNING podcast_clips.id) SELECT id::text FROM retried`, id).Scan(&retried)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
