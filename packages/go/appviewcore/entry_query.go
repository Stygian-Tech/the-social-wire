package appviewcore

type EntryQuery struct {
	ViewerDID        string
	AuthorDID        string
	PublicationID    string
	PublicationATURI string
	ScopeATURIs      []string
	SiteURLs         []string
	Filter           string
	Cursor           string
	Limit            int
}
