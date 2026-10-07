package publicationcore

import "time"

type SidebarRow struct {
	PublicationID             string       `json:"publicationId"`
	SubscriptionPublicationID *string      `json:"subscriptionPublicationId,omitempty"`
	AuthorDID                 string       `json:"authorDid"`
	AuthorHandle              *string      `json:"authorHandle,omitempty"`
	Title                     string       `json:"title"`
	IconURL                   *string      `json:"iconUrl,omitempty"`
	AvatarURL                 *string      `json:"avatarUrl,omitempty"`
	DiscoveredAt              time.Time    `json:"discoveredAt"`
	AppViewScope              AppViewScope `json:"appViewScope"`
	UnreadCount               *int         `json:"unreadCount,omitempty"`
}
