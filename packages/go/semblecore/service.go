package semblecore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
)

type Service struct {
	Transport Transport
	Reader    Reader
}

func (s Service) get(ctx context.Context, kind, path string, q url.Values, notFound bool) (map[string]any, error) {
	status, b, e := s.Transport.Get(ctx, path, q)
	if e != nil {
		var typed *Error
		if errors.As(e, &typed) {
			return nil, e
		}
		return nil, upstream("Semble public projection is unavailable.")
	}
	if notFound && status == 404 {
		return nil, NotFound
	}
	if status != 200 {
		return nil, upstream(fmt.Sprintf("Semble public projection failed with status %d.", status))
	}
	var out map[string]any
	if json.Unmarshal(b, &out) != nil || !validatePage(out, kind) {
		return nil, upstream("Semble public projection returned an invalid response.")
	}
	return out, nil
}

func query(cursor *string, limit int, sort string) (url.Values, error) {
	if limit < 1 || limit > 100 {
		return nil, Invalid("`limit` must be between 1 and 100.")
	}
	page, e := Page(cursor)
	if e != nil {
		return nil, e
	}
	return url.Values{"page": {strconv.Itoa(page)}, "limit": {strconv.Itoa(limit)}, "sortBy": {sort}, "sortOrder": {"desc"}}, nil
}
