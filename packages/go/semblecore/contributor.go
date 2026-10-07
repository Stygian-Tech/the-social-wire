package semblecore

type Contributor struct {
	DID         string  `json:"did"`
	Handle      *string `json:"handle,omitempty"`
	DisplayName *string `json:"displayName,omitempty"`
	Avatar      *string `json:"avatar,omitempty"`
}
