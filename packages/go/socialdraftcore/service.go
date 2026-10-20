package socialdraftcore

import (
	"context"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"
)

type Service struct {
	db        *sql.DB
	gcm       cipher.AEAD
	objects   objectStore
	admission admission
}

func New(db *sql.DB, c Config) (*Service, error) {
	u, e := url.Parse(c.Endpoint)
	if !c.Enabled || db == nil || e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || c.Bucket == "" || c.AccessKeyID == "" || c.SecretAccessKey == "" || c.Region == "" {
		return nil, ErrUnavailable
	}
	key, e := base64.StdEncoding.Strict().DecodeString(c.StorageKey)
	if e != nil || len(key) != 32 {
		return nil, ErrUnavailable
	}
	g, e := newGCM(key)
	if e != nil {
		return nil, ErrUnavailable
	}
	return &Service{db: db, gcm: g, objects: newS3Store(c)}, nil
}
func (s *Service) available() error {
	if s == nil || s.db == nil || s.gcm == nil || s.objects == nil {
		return ErrUnavailable
	}
	return nil
}

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var tidPattern = regexp.MustCompile(`^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$`)

func validOwner(o string) bool {
	return strings.HasPrefix(o, "did:") && len(o) <= 2048 && !strings.ContainsAny(o, "\x00\r\n")
}
func validReserve(in ReserveInput) bool {
	if !uuidPattern.MatchString(in.AssetID) || !utf8.ValidString(in.Name) || len(in.Name) == 0 || len(in.Name) > 1024 || strings.ContainsRune(in.Name, 0) || in.ByteLength <= 0 || in.ByteLength > MaxFileBytes {
		return false
	}
	h, e := hex.DecodeString(in.SHA256)
	if e != nil || len(h) != 32 || in.SHA256 != strings.ToLower(in.SHA256) {
		return false
	}
	switch in.Kind {
	case "photo", "poster", "gif", "video", "caption":
	default:
		return false
	}
	// Kind describes the draft's use of an asset; MIME describes its bytes.
	// Keep these allowlists independent (for example a GIF can be an image or MP4).
	switch in.ContentType {
	case "image/jpeg", "image/png", "image/webp", "image/gif", "video/mp4", "video/webm", "text/vtt":
		return true
	default:
		return false
	}
}

func (s *Service) asset(ctx context.Context, tx rowReader, owner, id string) (Asset, string, error) {
	var a Asset
	var metadata []byte
	var key string
	e := tx.QueryRowContext(ctx, `SELECT metadata,object_key,state FROM private_social_draft_assets WHERE owner=$1 AND asset_id=$2`, owner, id).Scan(&metadata, &key, &a.State)
	if e == sql.ErrNoRows {
		return a, "", ErrNotFound
	}
	if e != nil {
		return a, "", e
	}
	state := a.State
	if state == "deleted" || state == "purged" {
		return a, "", ErrNotFound
	}
	b, e := unseal(s.gcm, metadata, aad(owner, id, "metadata", 0))
	if e != nil {
		return a, "", ErrUnavailable
	}
	if json.Unmarshal(b, &a) != nil {
		return a, "", ErrUnavailable
	}
	a.State = state
	return a, key, nil
}
func (s *Service) Reserve(ctx context.Context, owner string, in ReserveInput) (Asset, error) {
	var zero Asset
	if e := s.available(); e != nil {
		return zero, e
	}
	if !validReserve(in) {
		return zero, ErrInvalid
	}
	tx, e := s.begin(ctx, owner)
	if e != nil {
		return zero, e
	}
	defer tx.Rollback()
	a, _, e := s.asset(ctx, tx, owner, in.AssetID)
	if e == nil {
		if a.Name != in.Name || a.ContentType != in.ContentType || a.ByteLength != in.ByteLength || a.SHA256 != in.SHA256 || a.Kind != in.Kind {
			return zero, ErrConflict
		}
		return a, tx.Commit()
	}
	if e != ErrNotFound {
		return zero, e
	}
	var exists bool
	if e = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM private_social_draft_assets WHERE owner=$1 AND asset_id=$2)`, owner, in.AssetID).Scan(&exists); e != nil {
		return zero, e
	}
	if exists {
		return zero, ErrAssetRetired
	}
	var used, count int64
	if e = tx.QueryRowContext(ctx, `SELECT COALESCE(sum(byte_length),0),count(*) FROM private_social_draft_assets WHERE owner=$1 AND state<>'purged'`, owner).Scan(&used, &count); e != nil {
		return zero, e
	}
	if used+in.ByteLength > MaxAccountBytes || count >= 10000 {
		return zero, ErrQuota
	}
	a = Asset{AssetID: in.AssetID, Name: in.Name, ContentType: in.ContentType, ByteLength: in.ByteLength, SHA256: in.SHA256, Kind: in.Kind, State: "reserved"}
	b, _ := json.Marshal(a)
	b, e = seal(s.gcm, b, aad(owner, in.AssetID, "metadata", 0))
	if e != nil {
		return zero, ErrUnavailable
	}
	keyBytes := make([]byte, 32)
	if _, e = rand.Read(keyBytes); e != nil {
		return zero, ErrUnavailable
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO private_social_draft_assets(owner,asset_id,metadata,byte_length,object_key,state) VALUES($1,$2,$3,$4,$5,'reserved')`, owner, in.AssetID, b, in.ByteLength, hex.EncodeToString(keyBytes)); e != nil {
		return zero, e
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO private_social_draft_cleanup(owner,asset_id) VALUES($1,$2)`, owner, in.AssetID); e != nil {
		return zero, e
	}
	return a, tx.Commit()
}
func (s *Service) Upload(ctx context.Context, owner, id string, body io.Reader, contentLength int64) (Asset, error) {
	var zero Asset
	if e := s.available(); e != nil {
		return zero, e
	}
	if !uuidPattern.MatchString(id) || body == nil {
		return zero, ErrInvalid
	}
	if !validOwner(owner) || contentLength <= 0 || contentLength > MaxFileBytes {
		return zero, ErrInvalid
	}
	release, e := s.admit(ctx, owner)
	if e != nil {
		return zero, e
	}
	defer release()
	// Read immutable reservation metadata without a transaction. Slow client input
	// never retains a connection or owner row lock.
	a, key, e := s.asset(ctx, s.db, owner, id)
	if e != nil {
		return zero, e
	}
	if contentLength != a.ByteLength {
		return zero, ErrInvalid
	}
	plain, e := tempFile()
	if e != nil {
		return zero, ErrUnavailable
	}
	defer discard(plain)
	h := sha256.New()
	n, e := io.Copy(io.MultiWriter(plain, h), io.LimitReader(&contextReader{ctx, body}, a.ByteLength+1))
	if e != nil {
		return zero, e
	}
	if n != a.ByteLength || hex.EncodeToString(h.Sum(nil)) != a.SHA256 {
		return zero, ErrInvalid
	}
	if e = validateContent(plain, a); e != nil {
		return zero, e
	}
	encrypted, e := tempFile()
	if e != nil {
		return zero, ErrUnavailable
	}
	defer discard(encrypted)
	if _, e = plain.Seek(0, io.SeekStart); e != nil {
		return zero, ErrUnavailable
	}
	if e = s.encrypt(encrypted, plain, owner, id); e != nil {
		return zero, ErrUnavailable
	}
	size, e := encrypted.Seek(0, io.SeekEnd)
	if e != nil {
		return zero, ErrUnavailable
	}
	if _, e = encrypted.Seek(0, io.SeekStart); e != nil {
		return zero, ErrUnavailable
	}
	// Only validated, fully encrypted local bytes enter the critical section.
	tx, e := s.beginAdmitted(ctx, owner)
	if e != nil {
		return zero, e
	}
	defer tx.Rollback()
	current, currentKey, e := s.asset(ctx, tx, owner, id)
	if e != nil {
		return zero, e
	}
	if currentKey != key || current.AssetID != a.AssetID || current.Name != a.Name || current.ContentType != a.ContentType || current.ByteLength != a.ByteLength || current.SHA256 != a.SHA256 || current.Kind != a.Kind {
		return zero, ErrConflict
	}
	if current.State == "ready" {
		return current, tx.Commit()
	}
	// Holding the owner lock through PUT and ready finalization prevents cleanup
	// or final detach from deleting the object and then allowing resurrection.
	// Reservation already has a durable cleanup job: even an ambiguous PUT or DB
	// commit failure leaves a recoverable object under the same immutable key.
	if e = s.objects.Put(ctx, key, encrypted, size); e != nil {
		return zero, ErrUnavailable
	}
	if _, e = tx.ExecContext(ctx, `UPDATE private_social_draft_assets SET state='ready' WHERE owner=$1 AND asset_id=$2`, owner, id); e != nil {
		return zero, e
	}
	a.State = "ready"
	return a, tx.Commit()
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if e := r.ctx.Err(); e != nil {
		return 0, e
	}
	return r.r.Read(p)
}
func validateContent(f io.ReadSeeker, a Asset) error {
	if _, e := f.Seek(0, io.SeekStart); e != nil {
		return ErrUnavailable
	}
	head := make([]byte, 512)
	n, e := io.ReadFull(f, head)
	if e != nil && e != io.EOF && e != io.ErrUnexpectedEOF {
		return ErrInvalid
	}
	head = head[:n]
	if a.ContentType == "text/vtt" {
		if _, e = f.Seek(0, io.SeekStart); e != nil {
			return ErrUnavailable
		}
		return validateCaption(f)
	}
	if http.DetectContentType(head) != a.ContentType {
		return ErrInvalid
	}
	return nil
}
func (s *Service) Download(ctx context.Context, owner, id string) (io.ReadCloser, Asset, error) {
	var zero Asset
	if e := s.available(); e != nil {
		return nil, zero, e
	}
	if !uuidPattern.MatchString(id) || !validOwner(owner) {
		return nil, zero, ErrInvalid
	}
	// Download admission belongs to the returned file, not the transaction.
	// This bounds plaintext disk usage even while downstream clients stream slowly.
	release, e := s.admit(ctx, owner)
	if e != nil {
		return nil, zero, e
	}
	transferred := false
	defer func() {
		if !transferred {
			release()
		}
	}()
	tx, e := s.beginAdmitted(ctx, owner)
	if e != nil {
		return nil, zero, e
	}
	defer tx.Rollback()
	a, key, e := s.asset(ctx, tx, owner, id)
	if e != nil {
		return nil, zero, e
	}
	if a.State != "ready" {
		return nil, zero, ErrUploadPending
	}
	r, e := s.objects.Get(ctx, key)
	if e != nil {
		return nil, zero, ErrUnavailable
	}
	defer r.Close()
	f, e := tempFile()
	if e != nil {
		return nil, zero, ErrUnavailable
	}
	ok := false
	defer func() {
		if !ok {
			discard(f)
		}
	}()
	h := sha256.New()
	if e = s.decrypt(io.MultiWriter(f, h), &contextReader{ctx, r}, owner, id, a.ByteLength); e != nil {
		return nil, zero, ErrUnavailable
	}
	if hex.EncodeToString(h.Sum(nil)) != a.SHA256 {
		return nil, zero, ErrUnavailable
	}
	if _, e = f.Seek(0, io.SeekStart); e != nil {
		return nil, zero, ErrUnavailable
	}
	if e = tx.Commit(); e != nil {
		return nil, zero, e
	}
	ok = true
	transferred = true
	return newTemporaryReader(ctx, f, release), a, nil
}
