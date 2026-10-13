package corpuscore

import (
	"context"
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

// The warm revision frames the current eligible ordered identities plus the
// authoritative generation tuple version. Payload/evidence/resolver updates move
// that tuple; current eligibility changes move the ordered key set. Neither a full
// generation aggregate nor a lean presentation aggregate is needed on a hit.
const sportsSourceProjection = `WITH current_source AS MATERIALIZED (
 SELECT generation.generation_id,generation.generated_at,generation.expires_at,
 catalog.version,catalog.generated_at AS lean_catalog_generated,
 encode(sha256(convert_to(jsonb_build_array(
 generation.generation_id::text,extract(epoch FROM generation.generated_at),
 extract(epoch FROM generation.expires_at),generation.language,generation.cache_revision,
 COALESCE((SELECT jsonb_agg(jsonb_build_array(candidate.ordinal,candidate.item_id) ORDER BY candidate.ordinal)
 FROM wire_serving.sports_source_candidates candidate WHERE candidate.generation_id=generation.generation_id),'[]'::jsonb)
 )::text,'UTF8')),'hex') AS revision
 FROM wire_serving.sports_source_heads generation CROSS JOIN wire_serving.sports_catalog catalog
 WHERE generation.language=$1 AND generation.is_active=TRUE AND generation.expires_at>$2 LIMIT 1) `

// CASE invokes this projection only on a server validation-cache miss, using the
// same statement snapshot as the metadata/eligibility revision.
const sportsSourceCandidatePayload = `COALESCE((SELECT jsonb_agg(jsonb_build_object(
 'itemId',candidate.candidate->'item'->>'itemId',
 'canonicalUrl',candidate.candidate->'item'->>'canonicalUrl',
 'title',candidate.candidate->'item'->>'title',
 'publishedAt',candidate.candidate->'item'->'publishedAt',
 'domain',candidate.candidate->'item'->'source'->>'domain',
 'presentationFingerprint',encode(sha256(convert_to(
 octet_length(COALESCE(candidate.candidate->'item'->>'title',''))::text||':'||COALESCE(candidate.candidate->'item'->>'title','')||
 CASE WHEN candidate.candidate->'item'->>'summary' IS NULL THEN 'N' ELSE 'S'||octet_length(candidate.candidate->'item'->>'summary')::text||':'||(candidate.candidate->'item'->>'summary') END||
 octet_length(COALESCE(candidate.candidate->'item'->'source'->>'domain',''))::text||':'||COALESCE(candidate.candidate->'item'->'source'->>'domain',''),'UTF8')),'hex'),
 'analysis',candidate.candidate->'analysis','baseScore',candidate.candidate->'baseScore','majorGlobal',candidate.candidate->'majorGlobal'
 ) ORDER BY candidate.ordinal) FROM wire_serving.sports_source_candidates candidate WHERE candidate.generation_id=current_source.generation_id),'[]'::jsonb)::text`

type sportsValidatedGeneration struct {
	id, revision string
	candidates   []SportsSourceCandidate
}

func (s *PostgreSQLStore) SportsSource(ctx context.Context, q SportsSourceRequest, now time.Time) (SportsSourceResponse, error) {
	if !ValidSportsSourceRequest(q) {
		return SportsSourceResponse{}, ErrContractMismatch
	}
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return SportsSourceResponse{}, err
	}
	s.sportsCatalogMu.Lock()
	validated := s.sportsValidatedGeneration
	s.sportsCatalogMu.Unlock()
	validatedID, validatedRevision := "", ""
	if validated != nil {
		validatedID, validatedRevision = validated.id, validated.revision
	}
	// Metadata, current eligibility/hash and payload suppression share one SQL
	// snapshot. A caller-supplied hash alone never bypasses strict validation.
	rows, err := s.query(ctx, sportsSourceProjection+`SELECT generation_id,generated_at,expires_at,version,lean_catalog_generated,revision,CASE WHEN generation_id::text=$3 AND revision=$4 THEN NULL ELSE `+sportsSourceCandidatePayload+` END FROM current_source`, q.Language, now, validatedID, validatedRevision)
	if err != nil {
		return SportsSourceResponse{}, err
	}
	if len(rows) != 1 {
		return SportsSourceResponse{}, ErrUnavailable
	}
	r := rows[0]
	out := SportsSourceResponse{GenerationID: strings.ToLower(r.String(0)), GeneratedAt: r.Time(1), ExpiresAt: r.Time(2), Language: q.Language, ResolverVersion: sportscore.ResolverVersion, CatalogVersion: r.String(3), CatalogGeneratedAt: r.Time(4).Format(time.RFC3339Nano)}
	out.GenerationRevision = r.String(5)
	if r.err != nil {
		return out, r.err
	}
	out.GenerationUnchanged = q.KnownGenerationID == out.GenerationID && q.KnownGenerationRevision == out.GenerationRevision
	rawCandidates := r.OptionalString(6)
	if r.err != nil {
		return out, r.err
	}
	var candidates []SportsSourceCandidate
	if rawCandidates == nil {
		if validated == nil || validated.id != out.GenerationID || validated.revision != out.GenerationRevision {
			return out, ErrContractMismatch
		}
		candidates = validated.candidates
	} else {
		// Retain at most one response-bounded, validated candidate generation.
		if len(*rawCandidates) > 8<<20 {
			return out, ErrUnavailable
		}
		if decodeContract([]byte(*rawCandidates), &candidates) != nil || len(candidates) > MaximumSportsCandidates {
			return out, ErrContractMismatch
		}
		for _, c := range candidates {
			if !validSportsSourceCandidate(c) {
				return out, ErrContractMismatch
			}
			if c.Analysis.ResolverVersion != sportscore.ResolverVersion {
				return out, ErrUnavailable
			}
			for _, a := range c.Analysis.Associations {
				if a.ResolverVersion != sportscore.ResolverVersion {
					return out, ErrUnavailable
				}
			}
		}
		if err := ctx.Err(); err != nil {
			return out, err
		}
		s.sportsCatalogMu.Lock()
		s.sportsValidatedGeneration = &sportsValidatedGeneration{id: out.GenerationID, revision: out.GenerationRevision, candidates: candidates}
		s.sportsCatalogMu.Unlock()
	}
	if observer := queryObserver(ctx); observer != nil {
		phase := "source-generation-cache-miss"
		if rawCandidates == nil {
			phase = "source-generation-cache-hit"
		}
		observer(phase, 0)
	}

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

	if !out.GenerationUnchanged {
		// Public responses must not expose mutable slices/pointers held by the
		// validation cache. The normal unchanged path allocates no candidate copy.
		responseCandidates := cloneSportsSourceCandidates(candidates)
		out.Candidates = &responseCandidates
	}

	if err := ctx.Err(); err != nil {
		return out, err
	}
	return out, nil
}

func cloneSportsSourceCandidates(source []SportsSourceCandidate) []SportsSourceCandidate {
	out := append([]SportsSourceCandidate{}, source...)
	for i := range out {
		if out[i].PublishedAt != nil {
			value := *out[i].PublishedAt
			out[i].PublishedAt = &value
		}
		out[i].Analysis.Associations = append([]sportscore.Association{}, source[i].Analysis.Associations...)
		for j := range out[i].Analysis.Associations {
			out[i].Analysis.Associations[j].Evidence = append([]string{}, source[i].Analysis.Associations[j].Evidence...)
		}
		out[i].Analysis.SportIDs = append([]string{}, source[i].Analysis.SportIDs...)
		out[i].Analysis.CompetitionIDs = append([]string{}, source[i].Analysis.CompetitionIDs...)
	}
	return out
}

// SportsSource restores conditional content only after the server revalidates
// its exact generation/catalog identities and current expiry. One retry without
// conditionals handles cache eviction or a concurrent request replacing cache.
func (s *RemoteStore) SportsSource(ctx context.Context, q SportsSourceRequest, now time.Time) (SportsSourceResponse, error) {
	if err := ctx.Err(); err != nil {
		return SportsSourceResponse{}, err
	}
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
			if !validSportsSourceCandidate(c) || c.Analysis.ResolverVersion != out.ResolverVersion {
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
		stored := out
		s.sportsCached = &stored
		s.sportsMu.Unlock()
		if observer := queryObserver(ctx); observer != nil {
			generationPhase := "source-generation-cache-miss"
			if out.GenerationUnchanged {
				generationPhase = "source-generation-cache-hit"
			}
			observer(generationPhase, 0)
		}
		owned := cloneSportsSourceCandidates(*out.Candidates)
		out.Candidates = &owned
		return out, nil
	}
	return SportsSourceResponse{}, ErrContractMismatch
}

func SportsSourceGeneration(out SportsSourceResponse) SportsGeneration {
	catalogDate, _ := time.Parse(time.RFC3339Nano, out.CatalogGeneratedAt)
	value := SportsGeneration{ServingCatalogRevision: out.ServingCatalogRevision, CatalogRevision: out.CatalogRevision, CatalogVersion: out.CatalogVersion, CatalogGeneratedAt: catalogDate, GenerationID: out.GenerationID, GeneratedAt: out.GeneratedAt, ExpiresAt: out.ExpiresAt, Language: out.Language, Candidates: []sportscore.RankCandidate{}, Entities: []sportscore.Entity{}}

	if out.Candidates != nil {
		for _, c := range *out.Candidates {
			// These presentation collections are deliberately absent from the lean
			// source, but persisted FeedItem contracts require arrays rather than null.
			value.Candidates = append(value.Candidates, sportscore.RankCandidate{Item: wirecore.FeedItem{ItemID: c.ItemID, CanonicalURL: c.CanonicalURL, Title: c.Title, PublishedAt: c.PublishedAt, Source: wirecore.ItemSource{Domain: c.Domain}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}, Analysis: c.Analysis, BaseScore: c.BaseScore, MajorGlobal: c.MajorGlobal, PresentationFingerprint: c.PresentationFingerprint})
		}
	}
	return value
}

var _ SportsSourceStore = (*PostgreSQLStore)(nil)
var _ SportsSourceStore = (*RemoteStore)(nil)
