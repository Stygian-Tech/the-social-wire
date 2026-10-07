package publicationcore

import "github.com/stygian-tech/the-social-wire/packages/go/appviewcore"

type AppViewScope struct {
	AuthorDID              string   `json:"authorDid"`
	PublicationATURI       *string  `json:"publicationAtUri,omitempty"`
	PublicationScopeATURIs []string `json:"publicationScopeAtUris"`
	PublicationSiteURLs    []string `json:"publicationSiteUrls"`
}

func (s AppViewScope) ReadScope(id string) appviewcore.PublicationScope {
	return appviewcore.PublicationScope{PublicationID: id, AuthorDID: s.AuthorDID, PublicationATURI: s.PublicationATURI, PublicationScopeATURIs: s.PublicationScopeATURIs, PublicationSiteURLs: s.PublicationSiteURLs}
}
