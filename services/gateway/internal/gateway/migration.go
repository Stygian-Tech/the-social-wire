package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"strings"
)

type MigrationSummary struct {
	FoldersCopied           int `json:"foldersCopied"`
	PublicationPrefsCopied  int `json:"publicationPrefsCopied"`
	PreferencesCopied       int `json:"preferencesCopied"`
	FoldersDeleted          int `json:"foldersDeleted"`
	PublicationPrefsDeleted int `json:"publicationPrefsDeleted"`
	PreferencesDeleted      int `json:"preferencesDeleted"`
}

func (p *Preferences) Migrate(ctx context.Context, a gatewaycore.AuthContext) (MigrationSummary, error) {
	summary := MigrationSummary{}
	for i, name := range []string{"folder", "publicationPrefs", "preferences"} {
		legacy, current := "com.thesocialwire."+name, "app.thesocialwire."+name
		probe, e := p.Repo.ListRecords(ctx, a.DID, legacy, "", 1, false)
		if e != nil {
			return summary, e
		}
		if len(probe.Records) == 0 {
			continue
		}
		var rows []gatewaycore.RepoRecord
		cursor := ""
		seen := map[string]bool{}
		for page := 0; page < 20; page++ {
			result, e := p.Repo.ListRecords(ctx, a.DID, legacy, cursor, 50, false)
			if e != nil {
				return summary, e
			}
			rows = append(rows, result.Records...)
			if result.Cursor == "" {
				break
			}
			if seen[result.Cursor] {
				return summary, fmt.Errorf("PDS pagination did not advance")
			}
			seen[result.Cursor] = true
			cursor = result.Cursor
		}
		for _, record := range rows {
			if e := ctx.Err(); e != nil {
				return summary, e
			}
			parts := strings.Split(record.URI, "/")
			key := parts[len(parts)-1]
			if key == "" {
				continue
			}
			existing, e := p.Repo.GetRecord(ctx, a.DID, current, key, "")
			if e != nil {
				return summary, e
			}
			if existing == nil {
				value := map[string]json.RawMessage{}
				for k, v := range record.Value {
					value[k] = v
				}
				raw, _ := json.Marshal(current)
				value["$type"] = raw
				destination := key
				if name == "preferences" {
					destination = "self"
				}
				if _, e = p.Repo.Mutate(ctx, a, "com.atproto.repo.putRecord", map[string]any{"collection": current, "rkey": destination, "record": value}); e != nil {
					return summary, e
				}
				switch i {
				case 0:
					summary.FoldersCopied++
				case 1:
					summary.PublicationPrefsCopied++
				case 2:
					summary.PreferencesCopied++
				}
			}
			if _, e = p.Repo.Mutate(ctx, a, "com.atproto.repo.deleteRecord", map[string]any{"collection": legacy, "rkey": key}); e != nil {
				return summary, e
			}
			switch i {
			case 0:
				summary.FoldersDeleted++
			case 1:
				summary.PublicationPrefsDeleted++
			case 2:
				summary.PreferencesDeleted++
			}
		}
	}
	return summary, nil
}
