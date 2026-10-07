package semblecore

type Item struct {
	ID              string      `json:"id"`
	CardURI         string      `json:"cardUri"`
	CardCID         *string     `json:"cardCid,omitempty"`
	CardType        string      `json:"cardType"`
	URL             *string     `json:"url,omitempty"`
	Title           *string     `json:"title,omitempty"`
	Description     *string     `json:"description,omitempty"`
	Image           *string     `json:"image,omitempty"`
	SiteName        *string     `json:"siteName,omitempty"`
	PublishedAt     *string     `json:"publishedAt,omitempty"`
	CreatedAt       *string     `json:"createdAt,omitempty"`
	Membership      *Membership `json:"membership,omitempty"`
	UnlinkAvailable bool        `json:"unlinkAvailable"`
	Contributor     Contributor `json:"contributor"`
	Note            *Note       `json:"note,omitempty"`
}
