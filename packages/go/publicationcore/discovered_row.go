package publicationcore

import "time"

type DiscoveredRow struct {
	PublicationID             string
	SubscriptionPublicationID *string
	AuthorDID                 string
	AuthorHandle              *string
	Title                     string
	IconURL, AvatarURL        *string
	DiscoveredAt              time.Time
}
