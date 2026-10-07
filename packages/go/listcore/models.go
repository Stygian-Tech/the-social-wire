package listcore

type Publication struct {
	PublicationID string  `json:"publicationId"`
	Title         string  `json:"title"`
	AuthorDID     string  `json:"authorDid"`
	AuthorHandle  *string `json:"authorHandle,omitempty"`
	IconURL       *string `json:"iconUrl,omitempty"`
	AvatarURL     *string `json:"avatarUrl,omitempty"`
}
type List struct {
	URI                string         `json:"uri"`
	Name               string         `json:"name"`
	Description        *string        `json:"description,omitempty"`
	CreatorDID         string         `json:"creatorDid"`
	Publications       []string       `json:"publications"`
	Users              []string       `json:"users"`
	Owned              bool           `json:"owned"`
	Saved              bool           `json:"saved"`
	PublicationDetails *[]Publication `json:"publicationDetails,omitempty"`
}
type Response struct {
	Lists       []List  `json:"lists"`
	RefreshedAt string  `json:"refreshedAt"`
	Complete    bool    `json:"complete"`
	CreatorDID  *string `json:"creatorDid,omitempty"`
}
