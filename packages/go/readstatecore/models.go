// Package readstatecore implements portable read-state protocol and projection rules.
package readstatecore

import (
	"errors"
	"time"
)

const (
	ManifestCollection       = "app.thesocialwire.readState"
	ChunkCollection          = "app.thesocialwire.readStateChunk"
	MaximumRecordBytes       = 65536
	MaximumSequence    int64 = 9007199254740991
)

var (
	ErrInvalidRecord        = errors.New("invalid read-state record")
	ErrInvalidReference     = errors.New("invalid read-state reference")
	ErrSizeLimit            = errors.New("read-state size limit")
	ErrConflictingSequence  = errors.New("conflicting read-state sequence")
	ErrIncompleteGeneration = errors.New("incomplete read-state generation")
)

type Reference struct {
	URI string `json:"uri"`
	CID string `json:"cid"`
}
type Scope struct {
	PublicationID       string   `json:"publicationId"`
	AuthorDID           string   `json:"authorDid"`
	PublicationSiteKeys []string `json:"publicationSiteKeys"`
}
type Boundary struct {
	Scope     Scope   `json:"scope"`
	CreatedAt string  `json:"createdAt"`
	EntryID   *string `json:"entryId,omitempty"`
}
type CalendarSelection struct {
	Cutoff        string `json:"cutoff"`
	TimeZone      string `json:"timeZone"`
	ReferenceDate string `json:"referenceDate"`
}
type State string

const (
	Read   State = "read"
	Unread State = "unread"
)

type Selection string

const (
	Boundaries Selection = "boundaries"
	Exact      Selection = "exact"
)

type Operation struct {
	ActionID    string             `json:"actionId"`
	Sequence    int64              `json:"sequence"`
	State       State              `json:"state"`
	ActedAt     string             `json:"actedAt"`
	Selection   Selection          `json:"selection"`
	Boundaries  []Boundary         `json:"boundaries,omitempty"`
	SubjectURIs []string           `json:"subjectUris,omitempty"`
	Calendar    *CalendarSelection `json:"calendar,omitempty"`
}
type Subject struct {
	URI, AuthorDID  string
	PublicationSite *string
	CreatedAt       time.Time
}
type Resolution struct {
	IsRead   bool
	ReadAt   *string
	Sequence int64
	ActionID *string
}
type Chunk struct {
	Type       string      `json:"$type"`
	Version    int         `json:"version"`
	Operations []Operation `json:"operations"`
	Previous   *Reference  `json:"previous,omitempty"`
}
type Manifest struct {
	Type               string     `json:"$type"`
	Version            int        `json:"version"`
	Generation         string     `json:"generation"`
	LastSequence       int64      `json:"lastSequence"`
	Head               *Reference `json:"head,omitempty"`
	Revision           *int64     `json:"revision,omitempty"`
	StateHead          *Reference `json:"stateHead,omitempty"`
	DevicesHead        *Reference `json:"devicesHead,omitempty"`
	LegacyReceiptsHead *Reference `json:"legacyReceiptsHead,omitempty"`
	CompactionVersion  *int       `json:"compactionVersion,omitempty"`
}
