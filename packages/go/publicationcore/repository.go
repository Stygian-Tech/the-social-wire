package publicationcore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Repository interface {
	GetRecord(context.Context, string, string, string, string) (*gatewaycore.RepoRecord, error)
	ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error)
	ResolvePDS(context.Context, string) (string, error)
	ResolveDID(context.Context, string) (string, error)
}

func listAll(ctx context.Context, repo Repository, did, collection string, maxPages int) ([]gatewaycore.RepoRecord, error) {
	rows := []gatewaycore.RepoRecord{}
	cursor := ""
	seen := map[string]bool{}
	for i := 0; i < maxPages; i++ {
		page, e := repo.ListRecords(ctx, did, collection, cursor, 50, false)
		if e != nil {
			return nil, e
		}
		rows = append(rows, page.Records...)
		if page.Cursor == "" {
			return rows, nil
		}
		if seen[page.Cursor] {
			return nil, errors.New("PDS pagination did not advance")
		}
		seen[page.Cursor] = true
		cursor = page.Cursor
	}
	return rows, nil
}
func recordValue(record gatewaycore.RepoRecord) map[string]any {
	value := map[string]any{}
	raw, _ := json.Marshal(record.Value)
	json.Unmarshal(raw, &value)
	return value
}
func text(value map[string]any, key string) string {
	s, _ := value[key].(string)
	return strings.TrimSpace(s)
}
func parseURI(raw string) (did, collection, key string, ok bool) {
	normal := NormalizeATRepoParam(raw)
	if !strings.HasPrefix(normal, "at://") {
		return
	}
	parts := strings.Split(strings.TrimPrefix(normal, "at://"), "/")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return
	}
	return parts[0], parts[1], parts[2], true
}
func publicJSON(ctx context.Context, client *http.Client, target string, maxBytes int, out any) error {
	work, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	r, e := http.NewRequestWithContext(work, "GET", target, nil)
	if e != nil {
		return e
	}
	r.Header.Set("Accept", "application/json")
	resp, e := client.Do(r)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return errors.New("public discovery dependency unavailable")
	}
	raw, e := io.ReadAll(io.LimitReader(resp.Body, int64(maxBytes)+1))
	if e != nil {
		return e
	}
	if len(raw) > maxBytes {
		return errors.New("public discovery response exceeds bound")
	}
	return json.Unmarshal(raw, out)
}
func queryURL(base, path string, q url.Values) string {
	return strings.TrimRight(base, "/") + path + "?" + q.Encode()
}
