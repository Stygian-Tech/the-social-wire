// Package readstatecore implements portable read-state protocol and projection rules.
package readstatecore

// Defines portable v1/v2 manifest, operation, boundary, and resolution fields with
// canonical JSON names. Pointers and nil slices preserve absent-field distinctions.
// Sequences are bounded to the interoperable JavaScript safe-integer maximum.

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

// Reference identifies a viewer-owned chunk by AT-URI and CID; validation does not fetch
// or verify the CID.
type Reference struct {
	URI string `json:"uri"`
	CID string `json:"cid"`
}

// Scope selects an author’s publication, optionally restricted to publication site keys.
type Scope struct {
	PublicationID       string   `json:"publicationId"`
	AuthorDID           string   `json:"authorDid"`
	PublicationSiteKeys []string `json:"publicationSiteKeys"`
}

// Boundary selects entries at or before a timestamp, with an optional inclusive entry-ID
// tie-break.
type Boundary struct {
	Scope     Scope   `json:"scope"`
	CreatedAt string  `json:"createdAt"`
	EntryID   *string `json:"entryId,omitempty"`
}

// CalendarSelection retains the civil-date/time-zone context of an exact bulk action.
type CalendarSelection struct {
	Cutoff        string `json:"cutoff"`
	TimeZone      string `json:"timeZone"`
	ReferenceDate string `json:"referenceDate"`
}

// State is the portable read or unread action value.
type State string

const (
	Read   State = "read"
	Unread State = "unread"
)

// Selection chooses exact subjects or scoped boundaries; the two selector forms are
// mutually exclusive.
type Selection string

const (
	Boundaries Selection = "boundaries"
	Exact      Selection = "exact"
)

// Operation is one sequenced logical action or split selector part, preserving canonical
// JSON field names.
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

// Subject supplies the identity, publication site, and creation instant needed for
// projection resolution.
type Subject struct {
	URI, AuthorDID  string
	PublicationSite *string
	CreatedAt       time.Time
}

// Resolution returns the winning sequence/action and read timestamp; no matching operation
// resolves unread.
type Resolution struct {
	IsRead   bool
	ReadAt   *string
	Sequence int64
	ActionID *string
}

// Chunk is a bounded v1 operation page optionally linked to the previous viewer-owned
// chunk.
type Chunk struct {
	Type       string      `json:"$type"`
	Version    int         `json:"version"`
	Operations []Operation `json:"operations"`
	Previous   *Reference  `json:"previous,omitempty"`
}

// Manifest describes v1 linked operations or the implemented v2 state/device/receipt head
// fields.
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
