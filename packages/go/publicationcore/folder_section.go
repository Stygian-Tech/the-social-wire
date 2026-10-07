package publicationcore

type FolderSection struct {
	FolderURI    string       `json:"folderUri"`
	FolderRKey   string       `json:"folderRkey"`
	Name         string       `json:"name"`
	Publications []SidebarRow `json:"publications"`
	UnreadCount  int          `json:"unreadCount"`
}
