package semblecore

type CollectionPage struct {
	Collection          Collection `json:"collection"`
	Items               []Item     `json:"items"`
	Cursor              *string    `json:"cursor,omitempty"`
	MembershipComplete  bool       `json:"membershipComplete"`
	RecordLinksComplete bool       `json:"recordLinksComplete"`
}
