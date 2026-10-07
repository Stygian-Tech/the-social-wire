package thinappviewcore

import (
	"net/url"
	"strings"
)

func PublicationIconURL(record map[string]any, repoDID, pdsBase string) *string {
	return PublicationImageURL(record, []string{"icon", "iconUrl", "iconImage", "iconImageUrl", "avatar", "avatarUrl", "logo", "logoUrl", "favicon"}, repoDID, pdsBase)
}
func PublicationImageURL(record map[string]any, keys []string, repoDID, pdsBase string) *string {
	for _, key := range keys {
		if raw, ok := record[key].(string); ok {
			lower := strings.ToLower(raw)
			if strings.HasPrefix(lower, "https://") || strings.HasPrefix(lower, "http://") {
				return &raw
			}
		}
		cid := ExtractBlobLink(record[key])
		if cid != "" && repoDID != "" {
			if blob := SyncGetBlobURL(pdsBase, repoDID, cid); blob != nil {
				return blob
			}
		}
	}
	return nil
}
func SyncGetBlobURL(pdsBase, repoDID, cid string) *string {
	if pdsBase == "" {
		return nil
	}
	base := strings.TrimRight(strings.TrimSpace(pdsBase), "/")
	u, err := url.Parse(base)
	if err != nil {
		return nil
	}
	host := strings.ToLower(u.Hostname())
	if host == "atproto.brid.gy" || strings.HasSuffix(host, ".brid.gy") {
		return nil
	}
	result := base + "/xrpc/com.atproto.sync.getBlob?" + url.Values{"did": {repoDID}, "cid": {cid}}.Encode()
	return &result
}
