package listcore

import (
	"net/url"
	"strings"
)

const Collection = "app.standard-reader.list"
const SaveCollection = "app.standard-reader.listSave"

type Identity struct{ DID, RKey string }

func (i Identity) URI() string { return "at://" + i.DID + "/" + Collection + "/" + i.RKey }

func ParseIdentity(input string) (Identity, bool) {
	raw := strings.TrimSpace(input)
	if !strings.HasPrefix(raw, "at://") {
		return Identity{}, false
	}
	parts := strings.Split(raw[5:], "/")
	if len(parts) != 3 || !strings.HasPrefix(parts[0], "did:") || len(strings.FieldsFunc(parts[0], func(r rune) bool { return r == ':' })) < 3 || len(parts[0]) > 2048 || parts[1] != Collection || parts[2] == "" || len(parts[2]) > 512 || parts[2] == "." || parts[2] == ".." {
		return Identity{}, false
	}
	for _, r := range parts[0] {
		if r > 127 || r <= 32 || r == '?' || r == '#' {
			return Identity{}, false
		}
	}
	for _, r := range parts[2] {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("._~:-", r)) {
			return Identity{}, false
		}
	}
	return Identity{parts[0], parts[2]}, true
}

// Official share links are parsed locally, never fetched as arbitrary URLs.
func ParseResolutionInput(input string) (Identity, bool) {
	if i, ok := ParseIdentity(input); ok {
		return i, true
	}
	u, err := url.Parse(strings.TrimSpace(input))
	if err != nil || u.Scheme != "https" || u.Host != "standard-reader.app" || u.User != nil || u.Port() != "" {
		return Identity{}, false
	}
	parts := strings.Split(u.EscapedPath(), "/")
	if len(parts) != 4 || parts[0] != "" || parts[1] != "l" {
		return Identity{}, false
	}
	did, err := url.PathUnescape(parts[2])
	if err != nil {
		return Identity{}, false
	}
	rkey, err := url.PathUnescape(parts[3])
	if err != nil {
		return Identity{}, false
	}
	return ParseIdentity("at://" + did + "/" + Collection + "/" + rkey)
}
