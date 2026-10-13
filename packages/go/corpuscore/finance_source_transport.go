package corpuscore

import (
	"context"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
)

const FinanceSourcePath = "/xrpc/app.thesocialwire.corpus.getFinanceGeneration"

type FinanceSourceRequest struct {
	Language                string `json:"language"`
	KnownGenerationID       string `json:"knownGenerationId,omitempty"`
	KnownGenerationRevision string `json:"knownGenerationRevision,omitempty"`
}
type FinanceSourceResponse struct {
	GenerationID        string             `json:"generationId"`
	GenerationRevision  string             `json:"generationRevision"`
	GeneratedAt         time.Time          `json:"generatedAt"`
	ExpiresAt           time.Time          `json:"expiresAt"`
	Language            string             `json:"language"`
	GenerationUnchanged bool               `json:"generationUnchanged"`
	Generation          *FinanceGeneration `json:"generation,omitempty"`
}
type FinanceSourceStore interface {
	FinanceSource(context.Context, FinanceSourceRequest, time.Time) (FinanceSourceResponse, error)
}
type financeValidatedGeneration struct {
	id, revision string
	generation   FinanceGeneration
}

func ValidFinanceSourceRequest(q FinanceSourceRequest) bool {
	return ValidSportsSourceRequest(SportsSourceRequest(q))
}

// Current item eligibility and instrument metadata enter the same statement's
// revision. Only a server-validated revision may suppress the database payload.
const financeSourceProjection = `WITH current_source AS MATERIALIZED (SELECT generation_id,generated_at,expires_at,payload,instruments,encode(sha256(convert_to(jsonb_build_array(payload,instruments)::text,'UTF8')),'hex') AS revision FROM wire_serving.finance_generations WHERE language=$1 AND is_active=TRUE AND expires_at>$2 LIMIT 1) `

func (s *PostgreSQLStore) FinanceSource(ctx context.Context, q FinanceSourceRequest, now time.Time) (FinanceSourceResponse, error) {
	if !ValidFinanceSourceRequest(q) {
		return FinanceSourceResponse{}, ErrContractMismatch
	}
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return FinanceSourceResponse{}, err
	}
	s.financeSourceMu.Lock()
	cached := s.financeValidated
	s.financeSourceMu.Unlock()
	knownID, knownRevision := "", ""
	if cached != nil {
		knownID, knownRevision = cached.id, cached.revision
	}
	rows, err := s.query(ctx, financeSourceProjection+`SELECT generation_id,generated_at,expires_at,revision,CASE WHEN generation_id::text=$3 AND revision=$4 THEN NULL ELSE payload::text END,CASE WHEN generation_id::text=$3 AND revision=$4 THEN NULL ELSE instruments::text END FROM current_source`, q.Language, now, knownID, knownRevision)
	if err != nil {
		return FinanceSourceResponse{}, err
	}
	if len(rows) != 1 {
		return FinanceSourceResponse{}, ErrUnavailable
	}
	row := rows[0]
	out := FinanceSourceResponse{GenerationID: strings.ToLower(row.String(0)), GeneratedAt: row.Time(1), ExpiresAt: row.Time(2), GenerationRevision: row.String(3), Language: q.Language}
	rawCandidates, rawInstruments := row.OptionalString(4), row.OptionalString(5)
	if row.err != nil {
		return out, row.err
	}
	var generation FinanceGeneration
	if rawCandidates == nil || rawInstruments == nil {
		if rawCandidates != nil || rawInstruments != nil || cached == nil || cached.id != out.GenerationID || cached.revision != out.GenerationRevision {
			return out, ErrContractMismatch
		}
		generation = cached.generation
	} else {
		if len(*rawCandidates)+len(*rawInstruments) > 8<<20 {
			return out, ErrUnavailable
		}
		generation = FinanceGeneration{GenerationID: out.GenerationID, GeneratedAt: out.GeneratedAt, ExpiresAt: out.ExpiresAt, Language: q.Language, Candidates: []financecore.RankCandidate{}, Instruments: []financecore.Instrument{}}
		if decodeContract([]byte(*rawCandidates), &generation.Candidates) != nil || decodeContract([]byte(*rawInstruments), &generation.Instruments) != nil || !validFinanceGeneration(generation) {
			return out, ErrContractMismatch
		}
		if err := ctx.Err(); err != nil {
			return out, err
		}
		s.financeSourceMu.Lock()
		s.financeValidated = &financeValidatedGeneration{out.GenerationID, out.GenerationRevision, generation}
		s.financeSourceMu.Unlock()
	}
	// Expiry/generated-at can change independently of the presentation revision.
	generation.GenerationID = out.GenerationID
	generation.GeneratedAt = out.GeneratedAt
	generation.ExpiresAt = out.ExpiresAt
	generation.Language = q.Language
	if observer := queryObserver(ctx); observer != nil {
		phase := "source-generation-cache-miss"
		if rawCandidates == nil {
			phase = "source-generation-cache-hit"
		}
		observer(phase, 0)
	}
	out.GenerationUnchanged = q.KnownGenerationID == out.GenerationID && q.KnownGenerationRevision == out.GenerationRevision
	if !out.GenerationUnchanged {
		value := cloneFinanceGeneration(generation)
		out.Generation = &value
	}
	if err := ctx.Err(); err != nil {
		return out, err
	}
	return out, nil
}

func (s *RemoteStore) FinanceSource(ctx context.Context, q FinanceSourceRequest, now time.Time) (FinanceSourceResponse, error) {
	if err := ctx.Err(); err != nil {
		return FinanceSourceResponse{}, err
	}
	if !ValidFinanceSourceRequest(q) {
		return FinanceSourceResponse{}, ErrContractMismatch
	}
	s.financeMu.Lock()
	cached := s.financeCached
	s.financeMu.Unlock()
	if cached != nil && cached.Language == q.Language && cached.ExpiresAt.After(now) {
		q.KnownGenerationID = cached.GenerationID
		q.KnownGenerationRevision = cached.GenerationRevision
	}
	for attempt := 0; attempt < 2; attempt++ {
		body, err := MarshalHTTP(q)
		if err != nil {
			return FinanceSourceResponse{}, err
		}
		out, err := remoteDecode[FinanceSourceResponse](ctx, s, "POST", FinanceSourcePath, body)
		if err != nil {
			return out, err
		}
		if !sportsSourceUUID.MatchString(out.GenerationID) || !sportsSourceRevision.MatchString(out.GenerationRevision) || out.Language != q.Language || !out.ExpiresAt.After(now) || out.GeneratedAt.IsZero() || out.ExpiresAt.Before(out.GeneratedAt) {
			return out, ErrContractMismatch
		}
		if out.GenerationUnchanged {
			if out.Generation != nil {
				return out, ErrContractMismatch
			}
			if cached == nil || q.KnownGenerationID != out.GenerationID || q.KnownGenerationRevision != out.GenerationRevision || cached.GenerationID != out.GenerationID || cached.GenerationRevision != out.GenerationRevision || cached.Language != out.Language || cached.Generation == nil {
				q.KnownGenerationID = ""
				q.KnownGenerationRevision = ""
				cached = nil
				continue
			}
			value := cached.Generation
			refreshed := *value
			refreshed.GeneratedAt = out.GeneratedAt
			refreshed.ExpiresAt = out.ExpiresAt
			out.Generation = &refreshed
		}
		if out.Generation == nil || out.Generation.GenerationID != out.GenerationID || out.Generation.Language != out.Language || !out.Generation.GeneratedAt.Equal(out.GeneratedAt) || !out.Generation.ExpiresAt.Equal(out.ExpiresAt) || !validFinanceGeneration(*out.Generation) {
			return out, ErrContractMismatch
		}
		if err := ctx.Err(); err != nil {
			return out, err
		}
		if observer := queryObserver(ctx); observer != nil {
			phase := "source-generation-cache-miss"
			if out.GenerationUnchanged {
				phase = "source-generation-cache-hit"
			}
			observer(phase, 0)
		}
		if err := ctx.Err(); err != nil {
			return out, err
		}
		s.financeMu.Lock()
		stored := out
		s.financeCached = &stored
		s.financeMu.Unlock()
		value := cloneFinanceGeneration(*out.Generation)
		out.Generation = &value
		if err := ctx.Err(); err != nil {
			return out, err
		}
		return out, nil
	}
	return FinanceSourceResponse{}, ErrContractMismatch
}

func cloneFinancePointer[T any](value *T) *T {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}
func cloneFinanceGeneration(source FinanceGeneration) FinanceGeneration {
	out := source
	out.Source = cloneFinancePointer(source.Source)
	out.Instruments = append([]financecore.Instrument{}, source.Instruments...)
	for i := range out.Instruments {
		v := &out.Instruments[i]
		v.Exchange = cloneFinancePointer(v.Exchange)
		v.ExchangeName = cloneFinancePointer(v.ExchangeName)
		v.MIC = cloneFinancePointer(v.MIC)
		v.ShareClassFIGI = cloneFinancePointer(v.ShareClassFIGI)
		v.CompositeFIGI = cloneFinancePointer(v.CompositeFIGI)
		v.Currency = cloneFinancePointer(v.Currency)
		v.TradingViewSymbol = cloneFinancePointer(v.TradingViewSymbol)
		v.Aliases = append([]string{}, v.Aliases...)
		v.SectorIDs = append([]string{}, v.SectorIDs...)
	}
	out.Candidates = append([]financecore.RankCandidate{}, source.Candidates...)
	for i := range out.Candidates {
		c := &out.Candidates[i]
		item := &c.Item
		item.RepresentativeURI = cloneFinancePointer(item.RepresentativeURI)
		item.Summary = cloneFinancePointer(item.Summary)
		item.PublishedAt = cloneFinancePointer(item.PublishedAt)
		item.ThumbnailURL = cloneFinancePointer(item.ThumbnailURL)
		item.Source.Publication = cloneFinancePointer(item.Source.Publication)
		item.Source.Author = cloneFinancePointer(item.Source.Author)
		item.Source.PublicationKey = cloneFinancePointer(item.Source.PublicationKey)
		item.Source.HomepageURL = cloneFinancePointer(item.Source.HomepageURL)
		item.Source.IconURL = cloneFinancePointer(item.Source.IconURL)
		item.Reasons = append(item.Reasons[:0:0], item.Reasons...)
		item.Provenance = append([]string{}, item.Provenance...)
		c.Analysis.ResolverVersion = cloneFinancePointer(c.Analysis.ResolverVersion)
		c.Analysis.MacroTopics = append([]string{}, c.Analysis.MacroTopics...)
		c.Analysis.SectorIDs = append([]string{}, c.Analysis.SectorIDs...)
		c.Analysis.Associations = append([]financecore.Association{}, c.Analysis.Associations...)
		for j := range c.Analysis.Associations {
			c.Analysis.Associations[j].Evidence = append([]string{}, c.Analysis.Associations[j].Evidence...)
		}
	}
	return out
}

var _ FinanceSourceStore = (*PostgreSQLStore)(nil)
var _ FinanceSourceStore = (*RemoteStore)(nil)
