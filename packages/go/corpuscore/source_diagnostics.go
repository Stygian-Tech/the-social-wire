package corpuscore

import (
	"context"
	"strings"
)

type sourceRequestIDKey struct{}

// ValidSourceRequestID restricts correlation metadata to a bounded opaque ID.
func ValidSourceRequestID(id string) string {
	if len(id) == 0 || len(id) > 128 {
		return ""
	}
	for _, c := range id {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.') {
			return ""
		}
	}
	return id
}

func WithSourceRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, sourceRequestIDKey{}, ValidSourceRequestID(id))
}

func SourceRequestID(ctx context.Context) string {
	id, _ := ctx.Value(sourceRequestIDKey{}).(string)
	return id
}

func sourceFamily(target string) string {
	path, _, _ := strings.Cut(target, "?")
	switch path {
	case "/internal/wire/v1/finance":
		return "finance"
	case "/internal/wire/v1/sports", SportsSourcePath:
		return "sports"
	}
	return ""
}
