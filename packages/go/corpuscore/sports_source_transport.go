package corpuscore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

const SportsSourcePath = "/xrpc/app.thesocialwire.corpus.getSportsGeneration"
const MaximumSportsCandidates = 5000
const MaximumSportsEntities = 50000

type SportsSourceRequest struct {
	Language                string `json:"language"`
	KnownGenerationID       string `json:"knownGenerationId,omitempty"`
	KnownGenerationRevision string `json:"knownGenerationRevision,omitempty"`
}

type SportsSourceCandidate struct {
	ItemID                  string                     `json:"itemId"`
	CanonicalURL            string                     `json:"canonicalUrl"`
	Title                   string                     `json:"title"`
	PublishedAt             *time.Time                 `json:"publishedAt,omitempty"`
	Domain                  string                     `json:"domain"`
	PresentationFingerprint string                     `json:"presentationFingerprint"`
	Analysis                sportscore.ArticleAnalysis `json:"analysis"`
	BaseScore               float64                    `json:"baseScore"`
	MajorGlobal             bool                       `json:"majorGlobal"`
}

type SportsSourceResponse struct {
	ServingCatalogRevision string                   `json:"servingCatalogRevision"`
	GenerationID           string                   `json:"generationId"`
	GenerationRevision     string                   `json:"generationRevision"`
	GeneratedAt            time.Time                `json:"generatedAt"`
	ExpiresAt              time.Time                `json:"expiresAt"`
	Language               string                   `json:"language"`
	ResolverVersion        string                   `json:"resolverVersion"`
	CatalogRevision        string                   `json:"catalogRevision"`
	CatalogVersion         string                   `json:"catalogVersion"`
	CatalogGeneratedAt     string                   `json:"catalogGeneratedAt"`
	GenerationUnchanged    bool                     `json:"generationUnchanged"`
	Candidates             *[]SportsSourceCandidate `json:"candidates,omitempty"`
}

type SportsSourceStore interface {
	SportsSource(context.Context, SportsSourceRequest, time.Time) (SportsSourceResponse, error)
}

var sportsSourceUUID = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
var sportsSourceRevision = regexp.MustCompile(`^[a-f0-9]{64}$`)

func ValidSportsSourceRequest(q SportsSourceRequest) bool {
	return len(q.Language) > 0 && len(q.Language) <= 35 && (q.KnownGenerationID == "" || sportsSourceUUID.MatchString(q.KnownGenerationID)) && (q.KnownGenerationRevision == "" || sportsSourceRevision.MatchString(q.KnownGenerationRevision))
}

type sportsCatalogCache struct {
	servingRevision string
	version         string
	generated       string
	revision        string
}

func (s *PostgreSQLStore) SportsSource(ctx context.Context, q SportsSourceRequest, now time.Time) (SportsSourceResponse, error) {
	if !ValidSportsSourceRequest(q) {
		return SportsSourceResponse{}, ErrContractMismatch
	}
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return SportsSourceResponse{}, err
	}
	// Project the CURRENT security-barrier serving payload into rank inputs in SQL.
	// Summary/presentation never crosses this DB hop; its exact equality fingerprint
	// is computed inside PostgreSQL. All source evidence and eligibility changes
	// enter the generation revision, even when the immutable generation ID stays.
	rows, err := s.query(ctx, `SELECT generation.generation_id,generation.generated_at,generation.expires_at,catalog.version,catalog.generated_at,COALESCE((SELECT jsonb_agg(jsonb_build_object(
 'itemId',candidate.value->'item'->>'itemId',
 'canonicalUrl',candidate.value->'item'->>'canonicalUrl',
 'title',candidate.value->'item'->>'title',
 'publishedAt',candidate.value->'item'->'publishedAt',
 'domain',candidate.value->'item'->'source'->>'domain',
 'presentationFingerprint',encode(sha256(convert_to(
 octet_length(COALESCE(candidate.value->'item'->>'title',''))::text||':'||COALESCE(candidate.value->'item'->>'title','')||
 CASE WHEN candidate.value->'item'->>'summary' IS NULL THEN 'N' ELSE 'S'||octet_length(candidate.value->'item'->>'summary')::text||':'||(candidate.value->'item'->>'summary') END||
 octet_length(COALESCE(candidate.value->'item'->'source'->>'domain',''))::text||':'||COALESCE(candidate.value->'item'->'source'->>'domain',''),'UTF8')),'hex'),
 'analysis',candidate.value->'analysis','baseScore',candidate.value->'baseScore','majorGlobal',candidate.value->'majorGlobal'
 ) ORDER BY candidate.ordinality) FROM jsonb_array_elements(generation.payload) WITH ORDINALITY candidate(value,ordinality)),'[]'::jsonb)::text
 FROM wire_serving.sports_generations generation CROSS JOIN wire_serving.sports_catalog catalog WHERE generation.language=$1 AND generation.is_active=TRUE AND generation.expires_at>$2 LIMIT 1`, q.Language, now)
	if err != nil {
		return SportsSourceResponse{}, err
	}
	if len(rows) != 1 {
		return SportsSourceResponse{}, ErrUnavailable
	}
	r := rows[0]
	out := SportsSourceResponse{GenerationID: strings.ToLower(r.String(0)), GeneratedAt: r.Time(1), ExpiresAt: r.Time(2), Language: q.Language, ResolverVersion: sportscore.ResolverVersion, CatalogVersion: r.String(3), CatalogGeneratedAt: r.Time(4).Format(time.RFC3339Nano)}
	rawCandidates := r.String(5)
	if r.err != nil {
		return out, r.err
	}
	var candidates []SportsSourceCandidate
	if decodeContract([]byte(rawCandidates), &candidates) != nil || len(candidates) > MaximumSportsCandidates {
		return out, ErrContractMismatch
	}
	for _, c := range candidates {
		if c.Analysis.ResolverVersion != sportscore.ResolverVersion {
			return out, ErrUnavailable
		}
		for _, a := range c.Analysis.Associations {
			if a.ResolverVersion != sportscore.ResolverVersion {
				return out, ErrUnavailable
			}
		}
	}
	sum := sha256.Sum256([]byte(rawCandidates))
	out.GenerationRevision = hex.EncodeToString(sum[:])

	s.sportsCatalogMu.Lock()
	cached := s.sportsSourceCatalogCache
	s.sportsCatalogMu.Unlock()
	catalogHit := cached != nil && cached.version == out.CatalogVersion && cached.generated == out.CatalogGeneratedAt
	if observer := queryObserver(ctx); observer != nil {
		phase := "source-catalog-cache-miss"
		if catalogHit {
			phase = "source-catalog-cache-hit"
		}
		observer(phase, 0)
	}
	if !catalogHit {
		catalogRows, err := s.query(ctx, `SELECT entities::text FROM wire_serving.sports_catalog WHERE version=$1 AND generated_at=$2 LIMIT 1`, out.CatalogVersion, out.CatalogGeneratedAt)
		if err != nil {
			return out, err
		}
		if len(catalogRows) != 1 {
			return out, ErrUnavailable
		}
		var entities []sportscore.Entity
		if decodeContract([]byte(catalogRows[0].String(0)), &entities) != nil || len(entities) == 0 || len(entities) > MaximumSportsEntities {
			return out, ErrContractMismatch
		}
		revision, err := sportscore.ServingCatalogRevision(entities)
		if err != nil {
			return out, err
		}
		active := []sportscore.Entity{}
		for _, e := range entities {
			if e.Active {
				active = append(active, e)
			}
		}
		servingRevision := revision
		if len(active) != len(entities) {
			servingRevision, err = sportscore.ServingCatalogRevision(active)
			if err != nil {
				return out, err
			}
		}
		cached = &sportsCatalogCache{version: out.CatalogVersion, generated: out.CatalogGeneratedAt, revision: revision, servingRevision: servingRevision}

		s.sportsCatalogMu.Lock()
		s.sportsSourceCatalogCache = cached
		s.sportsCatalogMu.Unlock()
	}
	out.CatalogRevision = cached.revision
	out.ServingCatalogRevision = cached.servingRevision

	out.GenerationUnchanged = q.KnownGenerationID == out.GenerationID && q.KnownGenerationRevision == out.GenerationRevision
	if !out.GenerationUnchanged {
		out.Candidates = &candidates
	}

	return out, nil
}

// SportsSource restores conditional content only after the server revalidates
// its exact generation/catalog identities and current expiry. One retry without
// conditionals handles cache eviction or a concurrent request replacing cache.
func (s *RemoteStore) SportsSource(ctx context.Context, q SportsSourceRequest, now time.Time) (SportsSourceResponse, error) {
	s.sportsMu.Lock()
	cached := s.sportsCached
	s.sportsMu.Unlock()
	if cached != nil && cached.Language == q.Language && cached.ExpiresAt.After(now) && cached.ResolverVersion == sportscore.ResolverVersion {
		q.KnownGenerationID = cached.GenerationID
		q.KnownGenerationRevision = cached.GenerationRevision
	}
	for attempt := 0; attempt < 2; attempt++ {
		body, err := MarshalHTTP(q)
		if err != nil {
			return SportsSourceResponse{}, err
		}
		out, err := remoteDecode[SportsSourceResponse](ctx, s, "POST", SportsSourcePath, body)
		if err != nil {
			return out, err
		}
		_, catalogDateErr := time.Parse(time.RFC3339Nano, out.CatalogGeneratedAt)
		if catalogDateErr != nil || out.CatalogVersion == "" || len(out.CatalogVersion) > 256 || !sportsSourceUUID.MatchString(out.GenerationID) || !sportsSourceRevision.MatchString(out.GenerationRevision) || out.Language != q.Language || !out.ExpiresAt.After(now) || out.ResolverVersion != sportscore.ResolverVersion || !sportsSourceRevision.MatchString(out.CatalogRevision) || !sportsSourceRevision.MatchString(out.ServingCatalogRevision) {
			return out, ErrContractMismatch
		}
		missing := false
		if out.GenerationUnchanged {
			if out.Candidates != nil {
				return out, ErrContractMismatch
			}
			if cached == nil || q.KnownGenerationID != out.GenerationID || q.KnownGenerationRevision != out.GenerationRevision || cached.GenerationRevision != out.GenerationRevision || cached.GenerationID != out.GenerationID || cached.Language != out.Language || cached.ResolverVersion != out.ResolverVersion {
				missing = true
			} else {
				out.Candidates = cached.Candidates
			}
		}

		if missing {
			q.KnownGenerationID = ""
			q.KnownGenerationRevision = ""
			cached = nil
			continue
		}
		if out.Candidates == nil || len(*out.Candidates) > MaximumSportsCandidates {
			return out, ErrContractMismatch
		}

		for _, c := range *out.Candidates {
			if c.ItemID == "" || !sportsSourceRevision.MatchString(c.PresentationFingerprint) || c.Analysis.ResolverVersion != out.ResolverVersion {
				return out, ErrContractMismatch
			}
			for _, a := range c.Analysis.Associations {
				if a.ResolverVersion != out.ResolverVersion {
					return out, ErrContractMismatch
				}
			}
		}

		if err := ctx.Err(); err != nil {
			return out, err
		}
		s.sportsMu.Lock()
		s.sportsCached = &out
		s.sportsMu.Unlock()
		if observer := queryObserver(ctx); observer != nil {
			generationPhase := "source-generation-cache-miss"
			if out.GenerationUnchanged {
				generationPhase = "source-generation-cache-hit"
			}
			observer(generationPhase, 0)
		}
		return out, nil
	}
	return SportsSourceResponse{}, ErrContractMismatch
}

func SportsSourceGeneration(out SportsSourceResponse) SportsGeneration {
	catalogDate, _ := time.Parse(time.RFC3339Nano, out.CatalogGeneratedAt)
	value := SportsGeneration{ServingCatalogRevision: out.ServingCatalogRevision, CatalogRevision: out.CatalogRevision, CatalogVersion: out.CatalogVersion, CatalogGeneratedAt: catalogDate, GenerationID: out.GenerationID, GeneratedAt: out.GeneratedAt, ExpiresAt: out.ExpiresAt, Language: out.Language, Candidates: []sportscore.RankCandidate{}, Entities: []sportscore.Entity{}}

	if out.Candidates != nil {
		for _, c := range *out.Candidates {
			value.Candidates = append(value.Candidates, sportscore.RankCandidate{Item: wirecore.FeedItem{ItemID: c.ItemID, CanonicalURL: c.CanonicalURL, Title: c.Title, PublishedAt: c.PublishedAt, Source: wirecore.ItemSource{Domain: c.Domain}}, Analysis: c.Analysis, BaseScore: c.BaseScore, MajorGlobal: c.MajorGlobal, PresentationFingerprint: c.PresentationFingerprint})
		}
	}
	return value
}

var _ SportsSourceStore = (*PostgreSQLStore)(nil)
var _ SportsSourceStore = (*RemoteStore)(nil)
