package corpuscore

import (
	"bytes"
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type RemoteConfig struct{ BaseURL, ServiceID, SharedSecret string }

func RemoteConfigFromEnvironment(env map[string]string) (*RemoteConfig, error) {
	value := func(key string) string { return strings.TrimSpace(env[key]) }
	base, service, secret := value("WIRE_CORPUS_EDGE_BASE_URL"), value("WIRE_CORPUS_EDGE_SERVICE_ID"), value("WIRE_CORPUS_EDGE_HMAC_SECRET")
	if base == "" && service == "" && secret == "" {
		return nil, nil
	}
	if base == "" || service == "" || len(secret) < 32 || !regexp.MustCompile(`^[a-zA-Z0-9._-]{1,64}$`).MatchString(service) {
		return nil, errors.New("invalid corpus remote configuration")
	}
	u, err := url.Parse(base)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New("invalid corpus remote origin")
	}
	host := strings.ToLower(u.Hostname())
	scheme := strings.ToLower(u.Scheme)
	local := strings.ToLower(env["APP_ENV"]) == "local" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
	private := strings.ToLower(env["APP_ENV"]) == "dev" && strings.HasSuffix(host, ".railway.internal") && host != "railway.internal"
	if scheme != "https" && !(scheme == "http" && (local || private)) {
		return nil, errors.New("invalid corpus remote origin")
	}
	u.Path = ""
	u.RawPath = ""
	u.Scheme = scheme
	return &RemoteConfig{u.String(), service, secret}, nil
}

type RemoteStore struct {
	Config               RemoteConfig
	Client               *http.Client
	Now                  func() time.Time
	MaximumResponseBytes int64
}

func NewRemoteStore(config RemoteConfig, client *http.Client) *RemoteStore {
	if client == nil {
		client = &http.Client{Transport: http.DefaultTransport}
	}
	copy := *client
	copy.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &RemoteStore{config, &copy, time.Now, 8 << 20}
}

var _ Store = (*RemoteStore)(nil)

func (s *RemoteStore) request(ctx context.Context, method, target string, body []byte, contract bool) ([]byte, int, error) {
	timeout := 6 * time.Second
	if method == "POST" {
		timeout = 8 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	r, err := http.NewRequestWithContext(ctx, method, s.Config.BaseURL+target, bytes.NewReader(body))
	if err != nil {
		return nil, 0, ErrUnavailable
	}
	var digest *string
	if body != nil {
		value := wirecore.CorpusBodyDigest(body)
		digest = &value
		r.Header.Set("Content-Type", "application/json")
	}
	headers, err := wirecore.SignCorpusRequest([]byte(s.Config.SharedSecret), s.Config.ServiceID, method, target, digest, s.Now(), "")
	if err != nil {
		return nil, 0, ErrUnavailable
	}
	r.Header.Set("Accept", "application/json")
	r.Header.Set(wirecore.CorpusServiceHeader, headers.ServiceID)
	r.Header.Set(wirecore.CorpusTimestampHeader, headers.Timestamp)
	r.Header.Set(wirecore.CorpusNonceHeader, headers.Nonce)
	r.Header.Set(wirecore.CorpusSignatureHeader, headers.Signature)
	if digest != nil {
		r.Header.Set(wirecore.CorpusBodyDigestHeader, *digest)
	}
	response, err := s.Client.Do(r)
	if err != nil {
		return nil, 0, ErrUnavailable
	}
	defer response.Body.Close()
	limit := s.MaximumResponseBytes
	if limit <= 0 {
		limit = 8 << 20
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, response.StatusCode, ErrUnavailable
	}
	if response.StatusCode == 410 {
		return nil, 410, ErrCursorExpired
	}
	if response.StatusCode == 404 {
		return data, 404, nil
	}
	if response.StatusCode != 200 {
		return nil, response.StatusCode, ErrUnavailable
	}
	if contract && response.Header.Get("X-Wire-Corpus-Contract") != "3" {
		return nil, 200, ErrContractMismatch
	}
	return data, 200, nil
}
func remoteDecode[T any](ctx context.Context, s *RemoteStore, method, target string, body []byte) (T, error) {
	var result T
	data, status, err := s.request(ctx, method, target, body, true)
	if err != nil {
		return result, err
	}
	if status != 200 {
		return result, ErrUnavailable
	}
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) || decodeContract(data, &result) != nil {
		return result, ErrContractMismatch
	}
	return result, nil
}
func remoteTarget(path string, values url.Values) string {
	target := "/internal/wire/v1/" + path
	if len(values) > 0 {
		target += "?" + values.Encode()
	}
	return target
}
func languageQuery(language string) url.Values { return url.Values{"language": {language}} }
func (s *RemoteStore) Ping(ctx context.Context) error {
	value, err := remoteDecode[struct {
		ContractVersion int `json:"contractVersion"`
	}](ctx, s, "GET", remoteTarget("contract", nil), nil)
	if err != nil {
		return err
	}
	if value.ContractVersion != 3 {
		return ErrContractMismatch
	}
	return nil
}
func (s *RemoteStore) RequireFreshBaseline(ctx context.Context, _ time.Time) error {
	data, status, err := s.request(ctx, "GET", "/readyz", nil, false)
	if err != nil {
		return err
	}
	var value struct {
		Service string `json:"service"`
		Status  string `json:"status"`
	}
	if status != 200 || decodeContract(data, &value) != nil || value.Service != "wire-corpus-edge" || value.Status != "ready" {
		return ErrUnavailable
	}
	return nil
}
func (s *RemoteStore) Feed(ctx context.Context, q FeedQuery, _ time.Time) (Page, error) {
	values := languageQuery(q.Language)
	values.Set("limit", strconv.Itoa(q.Limit))
	values.Set("startOrdinal", strconv.Itoa(q.StartOrdinal))
	if q.GenerationID != nil {
		values.Set("generationId", *q.GenerationID)
	}
	if q.FallbackLimit != nil {
		values.Set("fallbackLimit", strconv.Itoa(*q.FallbackLimit))
	}
	return remoteDecode[Page](ctx, s, "GET", remoteTarget("feed", values), nil)
}
func (s *RemoteStore) Edition(ctx context.Context, q EditionQuery, _ time.Time) (Edition, error) {
	values := languageQuery(q.Language)
	if q.Region != nil {
		values.Set("region", *q.Region)
	}
	if q.FallbackLimit != nil {
		values.Set("fallbackLimit", strconv.Itoa(*q.FallbackLimit))
	}
	return remoteDecode[Edition](ctx, s, "GET", remoteTarget("edition", values), nil)
}
func (s *RemoteStore) Item(ctx context.Context, id string, _ time.Time) (*Item, error) {
	data, status, err := s.request(ctx, "GET", remoteTarget("item", url.Values{"itemId": {id}}), nil, true)
	if err != nil {
		return nil, err
	}
	if status == 404 {
		return nil, nil
	}
	var value Item
	if status != 200 || decodeContract(data, &value) != nil {
		return nil, ErrContractMismatch
	}
	return &value, nil
}
func (s *RemoteStore) Catalog(ctx context.Context, _ time.Time) (Catalog, error) {
	return remoteDecode[Catalog](ctx, s, "GET", remoteTarget("catalog", nil), nil)
}
func (s *RemoteStore) CircleCandidates(ctx context.Context, q CandidateRequest, _ time.Time) (CandidateResponse, error) {
	body, err := MarshalHTTP(q)
	if err != nil || len(body) > 1<<20 {
		return CandidateResponse{}, ErrUnavailable
	}
	return remoteDecode[CandidateResponse](ctx, s, "POST", remoteTarget("circle-candidates", nil), body)
}
func (s *RemoteStore) Finance(ctx context.Context, language string, _ time.Time) (FinanceGeneration, error) {
	return remoteDecode[FinanceGeneration](ctx, s, "GET", remoteTarget("finance", languageQuery(language)), nil)
}
func (s *RemoteStore) Sports(ctx context.Context, language string, _ time.Time) (SportsGeneration, error) {
	value, err := remoteDecode[SportsGeneration](ctx, s, "GET", remoteTarget("sports", languageQuery(language)), nil)
	if err == nil && !currentSports(value.Candidates) {
		err = ErrUnavailable
	}
	return value, err
}
func (s *RemoteStore) SportsSchedules(ctx context.Context, _ time.Time) ([]ScheduleStatus, error) {
	return remoteDecode[[]ScheduleStatus](ctx, s, "GET", remoteTarget("sports/schedules", nil), nil)
}
func (s *RemoteStore) SportsStandings(ctx context.Context, preferred []string, _ time.Time) ([]sportscore.StandingSnapshot, error) {
	query := url.Values{}
	if len(preferred) > 0 {
		query.Set("preferredIDs", strings.Join(preferred, ","))
	}
	return remoteDecode[[]sportscore.StandingSnapshot](ctx, s, "GET", remoteTarget("sports/standings", query), nil)
}
func (s *RemoteStore) SportsEvents(ctx context.Context, q EventsQuery, _ time.Time) ([]sportscore.Event, error) {
	query := url.Values{"global": {strconv.FormatBool(q.Global)}}
	if len(q.CompetitionIDs) > 0 {
		query.Set("competitionIDs", strings.Join(q.CompetitionIDs, ","))
	}
	if len(q.EntityIDs) > 0 {
		query.Set("entityIDs", strings.Join(q.EntityIDs, ","))
	}
	if q.TeamIDs != nil {
		query.Set("teamIDs", strings.Join(q.TeamIDs, ","))
	}
	if len(q.PreferredIDs) > 0 {
		query.Set("preferredIDs", strings.Join(q.PreferredIDs, ","))
	}
	if q.TimeZone != nil {
		query.Set("timeZone", q.TimeZone.String())
	}
	return remoteDecode[[]sportscore.Event](ctx, s, "GET", remoteTarget("sports/events", query), nil)
}
