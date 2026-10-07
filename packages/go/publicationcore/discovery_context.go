package publicationcore

type DiscoveryContext struct {
	ViewerDID                                                     string
	Folders                                                       []FolderRecord
	Prefs                                                         []PreferenceRecord
	Subscribed, MyPublications, Unfoldered, Following, UniqueRows []DiscoveredRow
	EnrollAuthorDIDs                                              []string
	PrefsByPublicationID                                          map[string]PreferenceRecord
}
