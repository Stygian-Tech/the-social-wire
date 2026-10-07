package podcastcore

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"unicode"

	"github.com/rivo/uniseg"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

func normalizeSearch(s string) string {
	var b strings.Builder
	for _, r := range norm.NFD.String(cases.Fold().String(s)) {
		if !unicode.Is(unicode.Mn, r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}
func SearchMatches(query, title string, description *string, hosts []Person) bool {
	fields := []string{title}
	if description != nil {
		fields = append(fields, *description)
	}
	for _, h := range hosts {
		fields = append(fields, h.Name)
	}
	prose := normalizeSearch(strings.Join(fields, " "))
	for _, term := range strings.Fields(normalizeSearch(query)) {
		if !strings.Contains(prose, term) {
			return false
		}
	}
	return true
}
func SearchBinding(viewer string, r SearchRequest) string {
	kind, show := "all", ""
	if r.Kind != nil {
		kind = *r.Kind
	}
	if r.ShowID != nil {
		show = *r.ShowID
	}
	// Swift JSONEncoder escapes slashes in strings by default.
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode([]string{viewer, normalizeSearch(strings.TrimSpace(r.Query)), kind, show})
	data := bytes.TrimSuffix(buffer.Bytes(), []byte("\n"))
	data = []byte(strings.ReplaceAll(string(data), "/", `\/`))
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

type SearchCursor struct {
	Binding string `json:"binding"`
	Entity  int    `json:"entity"`
	ID      string `json:"id"`
}

func DecodeSearchCursor(value *string, binding string) (*SearchCursor, error) {
	if value == nil {
		return nil, nil
	}
	data, err := base64.StdEncoding.DecodeString(*value)
	if err != nil {
		return nil, ErrInvalidRequest
	}
	var c SearchCursor
	if err := decodeRequired(data, &c, "binding", "entity", "id"); err != nil || c.Binding != binding || (c.Entity != 0 && c.Entity != 1) || uniseg.GraphemeClusterCount(c.ID) > 2048 {
		return nil, ErrInvalidRequest
	}
	return &c, nil
}
func (c SearchCursor) Encode() (string, error) {
	data, err := json.Marshal(c)
	return base64.StdEncoding.EncodeToString(data), err
}
