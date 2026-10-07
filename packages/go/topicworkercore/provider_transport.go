package topicworkercore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
)

type ProviderTransport interface {
	Request(context.Context, string, string, []byte, map[string]string, int64, time.Duration) ([]byte, int, error)
}
type HTTPTransport struct{ Client *http.Client }

func NewHTTPTransport() *HTTPTransport {
	return &HTTPTransport{Client: &http.Client{Timeout: 30 * time.Second}}
}
func (t *HTTPTransport) Request(ctx context.Context, method, url string, body []byte, headers map[string]string, limit int64, timeout time.Duration) ([]byte, int, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	response, err := t.Client.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, 0, err
	}
	if int64(len(data)) > limit {
		return nil, 0, fmt.Errorf("provider response exceeds limit")
	}
	return data, response.StatusCode, nil
}
func pause(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (w *Worker) financeRequest(ctx context.Context, method, url string, body []byte, headers map[string]string, limit int64, timeout time.Duration) ([]byte, error) {
	for attempt := 0; attempt < 3; attempt++ {
		data, status, err := w.HTTP.Request(ctx, method, url, body, headers, limit, timeout)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if err == nil && (status < 500 || attempt == 2) {
			if status != 200 {
				return nil, fmt.Errorf("finance provider HTTP status %d", status)
			}
			return data, nil
		}
		if attempt == 2 {
			return nil, err
		}
		if err := pause(ctx, time.Duration(250*(attempt+1))*time.Millisecond); err != nil {
			return nil, err
		}
	}
	return nil, fmt.Errorf("finance provider unavailable")
}
func (w *Worker) mapFIGIs(ctx context.Context, ids []string) ([]financecore.Instrument, error) {
	if len(ids) == 0 || len(ids) > 10 {
		return nil, fmt.Errorf("invalid FIGI mapping batch")
	}
	body := []map[string]string{}
	for _, id := range ids {
		if id == "" || len(id) > 200 {
			return nil, fmt.Errorf("invalid FIGI")
		}
		body = append(body, map[string]string{"idType": "ID_BB_GLOBAL", "idValue": id})
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	headers := map[string]string{"Content-Type": "application/json"}
	if key := w.env["OPENFIGI_API_KEY"]; key != "" {
		headers["X-OPENFIGI-APIKEY"] = key
	}
	data, err := w.financeRequest(ctx, "POST", "https://api.openfigi.com/v3/mapping", payload, headers, 5000000, 20*time.Second)
	if err != nil {
		return nil, err
	}
	var envelopes []struct {
		Error json.RawMessage  `json:"error"`
		Data  []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(data, &envelopes); err != nil {
		var one struct {
			Error json.RawMessage  `json:"error"`
			Data  []map[string]any `json:"data"`
		}
		if err := json.Unmarshal(data, &one); err != nil {
			return nil, err
		}
		envelopes = append(envelopes, one)
	}
	if len(envelopes) == 0 {
		return nil, fmt.Errorf("empty FIGI envelopes")
	}
	result := []financecore.Instrument{}
	for _, envelope := range envelopes {
		if len(envelope.Error) > 0 {
			return nil, fmt.Errorf("FIGI mapping failed")
		}
		for _, row := range envelope.Data {
			figi, a := row["figi"].(string)
			name, b := row["name"].(string)
			ticker, c := row["ticker"].(string)
			if !a || !b || !c {
				continue
			}
			kind, _ := row["securityType2"].(string)
			if kind == "" {
				kind = "security"
			}
			optional := func(key string) *string {
				value, ok := row[key].(string)
				if !ok {
					return nil
				}
				return &value
			}
			result = append(result, financecore.Instrument{ID: financecore.InstrumentID("openfigi", figi), Name: name, Symbol: ticker, Kind: kind, ProviderID: figi, Exchange: optional("exchCode"), Currency: optional("currency"), MIC: optional("micCode"), ShareClassFIGI: optional("shareClassFIGI"), CompositeFIGI: optional("compositeFIGI"), Aliases: []string{}, SectorIDs: []string{}, IsActive: true})
		}
	}
	return result, nil
}
func (w *Worker) coins(ctx context.Context) ([]financecore.Instrument, error) {
	data, err := w.financeRequest(ctx, "GET", "https://api.coingecko.com/api/v3/coins/list", nil, nil, 10000000, 30*time.Second)
	if err != nil {
		return nil, err
	}
	var rows []map[string]string
	if err := json.Unmarshal(data, &rows); err != nil {
		return nil, err
	}
	result := []financecore.Instrument{}
	for _, row := range rows {
		id, a := row["id"]
		name, b := row["name"]
		symbol, c := row["symbol"]
		if a && b && c {
			result = append(result, financecore.Instrument{ID: financecore.InstrumentID("coingecko", id), Name: name, Symbol: strings.ToUpper(symbol), Kind: "crypto", ProviderID: id, Aliases: []string{}, SectorIDs: []string{}, IsActive: true})
		}
	}
	return result, nil
}
