package operationsapi

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"reflect"
	"sort"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5/pgconn"
)

func boundedText(value string, maximum int) string {
	runes := []rune(value)
	if len(runes) > maximum {
		runes = runes[:maximum]
	}
	return string(runes)
}
func BoundedAttributes(input map[string]string, maximumValueLength int) map[string]string {
	if maximumValueLength < 0 {
		maximumValueLength = 0
	}
	keys := make([]string, 0, len(input))
	for key := range input {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := map[string]string{}
	for i, key := range keys {
		if i >= 32 {
			break
		}
		prohibited := false
		for _, part := range []string{"authorization", "dpop", "cookie", "token", "secret", "password", "record", "body"} {
			if strings.Contains(strings.ToLower(key), part) {
				prohibited = true
				break
			}
		}
		if !prohibited {
			out[key] = boundedText(input[key], maximumValueLength)
		}
	}
	return out
}
func HashIdentity(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:12])
}
func safeIdentifier(value string, maximum int) string {
	return strings.ToLower(boundedText(strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return r
		}
		return '_'
	}, value), maximum))
}
func ErrorCategory(err error) string {
	if err == nil {
		return "unknown"
	}
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		parts := []string{"postgres", strings.ToLower(pg.Code)}
		for _, id := range []string{pg.TableName, pg.ColumnName} {
			if id != "" {
				parts = append(parts, safeIdentifier(id, 32))
			}
		}
		return strings.Join(parts, "_")
	}
	t := reflect.TypeOf(err)
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	name := t.Name()
	if name == "" {
		name = "unknown"
	}
	return safeIdentifier(name, 64)
}
