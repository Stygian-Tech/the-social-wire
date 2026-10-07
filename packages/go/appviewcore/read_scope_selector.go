package appviewcore

import (
	"errors"
	"strings"
)

type ReadScopeSelector struct {
	Kind          string  `json:"kind"`
	PublicationID *string `json:"publicationId,omitempty"`
	FolderRKey    *string `json:"folderRkey,omitempty"`
}

func (s ReadScopeSelector) Validate() error {
	switch s.Kind {
	case "publication":
		if s.PublicationID != nil && strings.TrimSpace(*s.PublicationID) != "" {
			return nil
		}
	case "folder":
		if s.FolderRKey != nil && strings.TrimSpace(*s.FolderRKey) != "" {
			return nil
		}
	case "subscribed", "following":
		return nil
	}
	return errors.New("invalid read scope")
}
