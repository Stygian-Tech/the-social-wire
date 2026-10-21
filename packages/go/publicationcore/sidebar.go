package publicationcore

import "time"

type Sidebar struct {
	subscriptionPublicationIDs []string

	ViewerDID                string             `json:"viewerDid"`
	Folders                  []FolderRecord     `json:"folders"`
	PublicationPrefs         []PreferenceRecord `json:"publicationPrefs"`
	FolderSections           []FolderSection    `json:"folderSections"`
	AllPublicationRows       []SidebarRow       `json:"allPublicationRows"`
	MyPublications           []SidebarRow       `json:"myPublications"`
	SubscribedUnfoldered     []SidebarRow       `json:"subscribedUnfoldered"`
	FollowingTabPublications []SidebarRow       `json:"followingTabPublications"`
	EnrollAuthorDIDs         []string           `json:"enrollAuthorDids"`
	TotalUnreadCount         int                `json:"totalUnreadCount"`
	RefreshedAt              time.Time          `json:"refreshedAt"`

	// Manual refresh can retain durable Following membership without display
	// metadata on this replica. Clients may retain matching cached rows only.
	RetainedFollowingPublicationIDs []string `json:"retainedFollowingPublicationIds,omitempty"`
}
