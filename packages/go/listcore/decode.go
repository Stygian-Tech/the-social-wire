package listcore

import (
	"encoding/json"
	"strings"
	"time"
	"unicode"

	"github.com/rivo/uniseg"
)

func PublicationIdentity(uri string) (did string, ok bool) {
	if !strings.HasPrefix(uri, "at://") || strings.ContainsAny(uri, "?#") || strings.ContainsFunc(uri, unicode.IsSpace) {
		return "", false
	}
	parts := strings.Split(uri[5:], "/")
	if len(parts) != 3 || !strings.HasPrefix(parts[0], "did:") || parts[1] != "site.standard.publication" || parts[2] == "" {
		return "", false
	}
	return parts[0], true
}

func Decode(data []byte, identity Identity, viewer string, saved bool) (*List, error) {
	var record struct {
		Name         *string         `json:"name"`
		Description  json.RawMessage `json:"description"`
		CreatedAt    *string         `json:"createdAt"`
		Publications *[]string       `json:"publications"`
		Users        *[]string       `json:"users"`
	}
	if err := json.Unmarshal(data, &record); err != nil {
		return nil, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, err
	}
	if users, exists := fields["users"]; exists && string(users) == "null" {
		return nil, nil
	}
	var description *string
	// Swift's optional string extraction ignores non-string description fields.
	if err := json.Unmarshal(record.Description, &description); err != nil {
		description = nil
	}
	if record.Name == nil || strings.TrimSpace(*record.Name) == "" || uniseg.GraphemeClusterCount(*record.Name) > 64 || len(*record.Name) > 640 || record.CreatedAt == nil || record.Publications == nil || len(*record.Publications) > 500 {
		return nil, nil
	}
	if _, err := time.Parse(time.RFC3339Nano, *record.CreatedAt); err != nil {
		return nil, nil
	}
	for _, uri := range *record.Publications {
		if _, ok := PublicationIdentity(uri); !ok {
			return nil, nil
		}
	}
	users := []string{}
	if record.Users != nil {
		if len(*record.Users) > 500 {
			return nil, nil
		}
		for _, did := range *record.Users {
			if !strings.HasPrefix(did, "did:") || strings.Contains(did, "/") || strings.ContainsFunc(did, unicode.IsSpace) {
				return nil, nil
			}
		}
		users = unique(*record.Users)
	}
	if description != nil && (uniseg.GraphemeClusterCount(*description) > 300 || len(*description) > 3000) {
		return nil, nil
	}
	return &List{URI: identity.URI(), Name: *record.Name, Description: description, CreatorDID: identity.DID, Publications: unique(*record.Publications), Users: users, Owned: identity.DID == viewer, Saved: saved}, nil
}

func unique(values []string) []string {
	result := []string{}
	seen := map[string]bool{}
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	return result
}
