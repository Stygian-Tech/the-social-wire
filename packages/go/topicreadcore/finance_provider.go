package topicreadcore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"time"
)

type FinanceSearchProvider interface {
	Search(context.Context, string) ([]financecore.Instrument, error)
}
type OpenFIGISearch struct {
	Key    *string
	Client *http.Client
	URL    string
}

func NewOpenFIGISearch(key *string, client *http.Client) *OpenFIGISearch {
	if client == nil {
		client = gatewaycore.NewPublicHTTPClient(nil)
	}
	return &OpenFIGISearch{key, client, "https://api.openfigi.com/v3/search"}
}
func (p *OpenFIGISearch) Search(ctx context.Context, query string) ([]financecore.Instrument, error) {
	body, _ := json.Marshal(map[string]string{"query": query})
	var raw []byte
	var status int
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		request, err := http.NewRequestWithContext(requestCtx, "POST", p.URL, bytes.NewReader(body))
		if err != nil {
			cancel()
			return nil, err
		}
		request.Header.Set("Content-Type", "application/json")
		if p.Key != nil {
			request.Header.Set("X-OPENFIGI-APIKEY", *p.Key)
		}
		reply, err := p.Client.Do(request)
		if err == nil {
			status = reply.StatusCode
			raw, err = io.ReadAll(io.LimitReader(reply.Body, 5000001))
			reply.Body.Close()
			if len(raw) > 5000000 {
				err = errors.New("Finance provider response too large")
			}
		}
		cancel()
		last = err
		if attempt == 2 || (err == nil && status < 500) {
			break
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		timer := time.NewTimer(time.Duration(250*(attempt+1)) * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	if last != nil {
		return nil, last
	}
	if status != 200 {
		return nil, ErrUnavailable
	}
	var object any
	if json.Unmarshal(raw, &object) != nil {
		return nil, ErrUnavailable
	}
	envelopes := []any{}
	switch value := object.(type) {
	case []any:
		envelopes = value
	case map[string]any:
		envelopes = []any{value}
	}
	if len(envelopes) == 0 {
		return nil, ErrUnavailable
	}
	result := []financecore.Instrument{}
	stringPtr := func(value any) *string {
		if text, ok := value.(string); ok {
			return &text
		}
		return nil
	}
	for _, raw := range envelopes {
		envelope, ok := raw.(map[string]any)
		if !ok {
			return nil, ErrUnavailable
		}
		if _, exists := envelope["error"]; exists {
			return nil, ErrUnavailable
		}
		rows, _ := envelope["data"].([]any)
		for _, raw := range rows {
			row, _ := raw.(map[string]any)
			figi, fok := row["figi"].(string)
			name, nok := row["name"].(string)
			ticker, tok := row["ticker"].(string)
			if !fok || !nok || !tok {
				continue
			}
			kind := "security"
			if value, ok := row["securityType2"].(string); ok {
				kind = value
			}
			result = append(result, financecore.Instrument{ID: financecore.InstrumentID("openfigi", figi), Name: name, Symbol: ticker, Kind: kind, ProviderID: figi, Exchange: stringPtr(row["exchCode"]), Currency: stringPtr(row["currency"]), MIC: stringPtr(row["micCode"]), ShareClassFIGI: stringPtr(row["shareClassFIGI"]), CompositeFIGI: stringPtr(row["compositeFIGI"]), Aliases: []string{}, SectorIDs: []string{}, IsActive: true})
		}
	}
	return result, nil
}
