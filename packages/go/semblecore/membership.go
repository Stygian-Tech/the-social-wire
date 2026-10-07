package semblecore

type Membership struct {
	LinkURI     string  `json:"linkUri"`
	LinkCID     *string `json:"linkCid,omitempty"`
	AuthorDID   string  `json:"authorDid"`
	AddedBy     string  `json:"addedBy"`
	AddedAt     *string `json:"addedAt,omitempty"`
	ViewerOwned bool    `json:"viewerOwned"`
}
