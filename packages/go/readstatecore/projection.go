package readstatecore

// Builds an immutable indexed snapshot from validated operations. Resolution selects the
// greatest applicable sequence across exact subjects and author/site boundaries; timestamp
// equality uses the boundary entry ID as an inclusive tie-break.

import (
	"reflect"
	"slices"
	"time"
)

type scopedOperation struct {
	boundary  Boundary
	date      time.Time
	operation Operation
}

// Projection is immutable; construction clones nested slices before publishing.
type Projection struct {
	exact        map[string]Operation
	scoped       map[string][]scopedOperation
	lastSequence int64
	operations   []Operation
	actions      map[string]bool
}

func cloneOperation(operation Operation) Operation {
	operation.SubjectURIs = slices.Clone(operation.SubjectURIs)
	operation.Boundaries = slices.Clone(operation.Boundaries)
	for itemIndex := range operation.Boundaries {
		operation.Boundaries[itemIndex].Scope.PublicationSiteKeys = slices.Clone(operation.Boundaries[itemIndex].Scope.PublicationSiteKeys)
		if operation.Boundaries[itemIndex].EntryID != nil {
			value := *operation.Boundaries[itemIndex].EntryID
			operation.Boundaries[itemIndex].EntryID = &value
		}
	}
	if operation.Calendar != nil {
		calendarSelection := *operation.Calendar
		operation.Calendar = &calendarSelection
	}
	return operation
}

// NewProjection clones and validates operations, rejects conflicting action/sequence
// assignments, and checks v1 generation completeness.
func NewProjection(operations []Operation, lastSequence int64, protocolVersion int) (*Projection, error) {
	if lastSequence < 0 || lastSequence > MaximumSequence || (protocolVersion != 1 && protocolVersion != 2) {
		return nil, ErrInvalidRecord
	}
	projection := &Projection{exact: map[string]Operation{}, scoped: map[string][]scopedOperation{}, lastSequence: lastSequence, actions: map[string]bool{}}
	sequences := map[int64]Operation{}
	actions := map[string]int64{}
	maximum := int64(0)
	for _, input := range operations {
		operation := cloneOperation(input)
		if err := ValidateOperation(operation); err != nil {
			return nil, err
		}
		if operation.Sequence > lastSequence {
			return nil, ErrInvalidRecord
		}
		if other, ok := sequences[operation.Sequence]; ok && (other.ActionID != operation.ActionID || other.State != operation.State || other.ActedAt != operation.ActedAt || !reflect.DeepEqual(other.Calendar, operation.Calendar)) {
			return nil, ErrConflictingSequence
		}
		if sequence, ok := actions[operation.ActionID]; ok && sequence != operation.Sequence {
			return nil, ErrConflictingSequence
		}
		sequences[operation.Sequence] = operation
		actions[operation.ActionID] = operation.Sequence
		projection.actions[operation.ActionID] = true
		maximum = max(maximum, operation.Sequence)
		projection.operations = append(projection.operations, operation)
		for _, uri := range operation.SubjectURIs {
			if projection.exact[uri].Sequence < operation.Sequence {
				projection.exact[uri] = operation
			}
		}
		for _, boundary := range operation.Boundaries {
			date, _ := ParseDate(boundary.CreatedAt)
			projection.scoped[boundary.Scope.AuthorDID] = append(projection.scoped[boundary.Scope.AuthorDID], scopedOperation{boundary, date, operation})
		}
	}
	if protocolVersion == 1 && maximum != lastSequence {
		return nil, ErrIncompleteGeneration
	}
	return projection, nil
}

// LastSequence returns the snapshot’s declared sequence ceiling.
func (projection *Projection) LastSequence() int64 { return projection.lastSequence }

// HasAction reports whether construction included the supplied logical action ID.
func (projection *Projection) HasAction(id string) bool { return projection.actions[id] }

// Operations returns deep copies so callers cannot mutate the indexed snapshot.
func (projection *Projection) Operations() []Operation {
	result := make([]Operation, len(projection.operations))
	for itemIndex, operation := range projection.operations {
		result[itemIndex] = cloneOperation(operation)
	}
	return result
}

// Resolve selects the latest applicable exact or author/site-boundary action without
// mutating the snapshot.
func (projection *Projection) Resolve(subject Subject) Resolution {
	latest := projection.exact[subject.URI]
	for _, item := range projection.scoped[subject.AuthorDID] {
		if item.operation.Sequence <= latest.Sequence {
			continue
		}
		keys := item.boundary.Scope.PublicationSiteKeys
		if len(keys) > 0 && (subject.PublicationSite == nil || !slices.Contains(keys, *subject.PublicationSite)) {
			continue
		}
		if subject.CreatedAt.Before(item.date) || (subject.CreatedAt.Equal(item.date) && (item.boundary.EntryID == nil || *item.boundary.EntryID >= subject.URI)) {
			latest = item.operation
		}
	}
	resolution := Resolution{IsRead: latest.State == Read, Sequence: latest.Sequence}
	if latest.Sequence > 0 {
		action := latest.ActionID
		resolution.ActionID = &action
	}
	if resolution.IsRead {
		at := latest.ActedAt
		resolution.ReadAt = &at
	}
	return resolution
}
