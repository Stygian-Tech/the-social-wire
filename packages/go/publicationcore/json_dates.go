package publicationcore

import (
	"encoding/json"
	"time"
)

func (s Sidebar) MarshalJSON() ([]byte, error) {
	type fields Sidebar
	return json.Marshal(struct {
		fields
		RefreshedAt string `json:"refreshedAt"`
	}{fields(s), s.RefreshedAt.UTC().Format(time.RFC3339)})
}
func (s SidebarRow) MarshalJSON() ([]byte, error) {
	type fields SidebarRow
	return json.Marshal(struct {
		fields
		DiscoveredAt string `json:"discoveredAt"`
	}{fields(s), s.DiscoveredAt.UTC().Format(time.RFC3339)})
}
func (s CounterSnapshot) MarshalJSON() ([]byte, error) {
	type fields CounterSnapshot
	return json.Marshal(struct {
		fields
		CountedAt string `json:"countedAt"`
	}{fields(s), s.CountedAt.UTC().Format(time.RFC3339)})
}
