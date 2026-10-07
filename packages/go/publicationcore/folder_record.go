package publicationcore

type FolderRecord struct {
	URI   string         `json:"uri"`
	RKey  string         `json:"rkey"`
	Value map[string]any `json:"value"`
}
