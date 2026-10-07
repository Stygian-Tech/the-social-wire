package semblecore

type ConnectionsResponse struct {
	Connections         []Connection `json:"connections"`
	Cursor              *string      `json:"cursor,omitempty"`
	RecordLinksComplete bool         `json:"recordLinksComplete"`
}
