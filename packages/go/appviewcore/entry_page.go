package appviewcore

type EntryPage struct {
	Entries []Entry `json:"entries"`
	Cursor  *string `json:"cursor,omitempty"`
}
