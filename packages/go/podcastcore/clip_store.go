package podcastcore

import "context"

func (s *Store) PrepareClip(ctx context.Context, viewer string, clip Clip, payload string) (string, error) {
	if !uuidPattern.MatchString(clip.ID) || IsPrivateID(clip.EpisodeID) {
		return "", ErrInvalidRequest
	}
	id, err := newUUID()
	if err != nil {
		return "", err
	}
	data, err := jsonValue(clip)
	if err != nil {
		return "", err
	}
	var result string
	err = s.DB.QueryRowContext(ctx, `WITH draft AS (INSERT INTO podcast_clips(id,viewer_did,episode_id,clip_json) VALUES($1::uuid,$2,$3,$4::jsonb) RETURNING id) INSERT INTO podcast_jobs(id,viewer_did,episode_id,kind,dedupe_key,payload_json) SELECT $5::uuid,$2,$3,'clip',$6,$7::jsonb FROM draft RETURNING id::text`, clip.ID, viewer, clip.EpisodeID, data, id, "clip:"+clip.ID, payload).Scan(&result)
	return result, err
}
func (s *Store) RemoveClip(ctx context.Context, viewer string, clip Clip, payload string) error {
	id, err := newUUID()
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `WITH removed AS (DELETE FROM podcast_clips WHERE id::text=$1 AND viewer_did=$2 RETURNING id) INSERT INTO podcast_jobs(id,viewer_did,episode_id,kind,dedupe_key,payload_json) SELECT $3::uuid,$2,$4,'cleanup',$5,$6::jsonb FROM removed ON CONFLICT(dedupe_key) DO NOTHING`, clip.ID, viewer, id, clip.EpisodeID, "cleanup:"+clip.ID, payload)
	return err
}
func (s *Store) CreateClip(ctx context.Context, viewer string, clip Clip) error {
	if !uuidPattern.MatchString(clip.ID) {
		return ErrInvalidRequest
	}
	data, err := jsonValue(clip)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `INSERT INTO podcast_clips(id,viewer_did,episode_id,clip_json) VALUES($1::uuid,$2,$3,$4::jsonb)`, clip.ID, viewer, clip.EpisodeID, data)
	return err
}
func (s *Store) Clips(ctx context.Context, viewer string) ([]Clip, error) {
	return manyJSON[Clip](ctx, s.DB, `SELECT (clip_json || jsonb_build_object('jobId',(SELECT id::text FROM podcast_jobs WHERE podcast_jobs.payload_json->>'clipId'=podcast_clips.id::text AND kind='clip' ORDER BY created_at DESC LIMIT 1)))::text FROM podcast_clips WHERE viewer_did=$1 ORDER BY updated_at DESC LIMIT 100`, viewer)
}
func (s *Store) Clip(ctx context.Context, id string, viewer *string, publishedOnly bool) (*Clip, error) {
	return singleJSON[Clip](ctx, s.DB, `SELECT clip_json::text FROM podcast_clips WHERE (id::text=$1 OR published_uri=$1) AND ($2::text IS NULL OR viewer_did=$2) AND (NOT $3 OR published_uri IS NOT NULL) LIMIT 1`, id, viewer, publishedOnly)
}
func (s *Store) PublishClip(ctx context.Context, id, viewer, uri string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE podcast_clips SET published_uri=$1,clip_json=jsonb_set(clip_json,'{publishedUri}',to_jsonb($1::text)),updated_at=now() WHERE id::text=$2 AND viewer_did=$3`, uri, id, viewer)
	return err
}
func (s *Store) DeleteClip(ctx context.Context, id, viewer string) error {
	_, err := s.DB.ExecContext(ctx, `DELETE FROM podcast_clips WHERE id::text=$1 AND viewer_did=$2`, id, viewer)
	return err
}
