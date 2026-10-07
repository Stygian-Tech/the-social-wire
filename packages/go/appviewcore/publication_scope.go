package appviewcore

type PublicationScope struct {
	PublicationID          string   `json:"publicationId"`
	AuthorDID              string   `json:"authorDid"`
	PublicationATURI       *string  `json:"publicationAtUri,omitempty"`
	PublicationScopeATURIs []string `json:"publicationScopeAtUris"`
	PublicationSiteURLs    []string `json:"publicationSiteUrls"`
}
