package readstate

import r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"

type preparedSelection struct {
	ActedAt            string               `json:"actedAt"`
	Selection          r.Selection          `json:"selection"`
	Boundaries         *[]r.Boundary        `json:"boundaries,omitempty"`
	SubjectURIs        *[]string            `json:"subjectUris,omitempty"`
	Calendar           *r.CalendarSelection `json:"calendar,omitempty"`
	LegacyRevision     int64                `json:"legacyRevision"`
	ManifestCID        *string              `json:"manifestCid,omitempty"`
	PreviewSubjectURIs *[]string            `json:"previewSubjectUris,omitempty"`
}
