package publicationcore

import "time"

type Sidebar struct {
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
}
