package readstatecore

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

func cloneOperation(o Operation) Operation {
	o.SubjectURIs = slices.Clone(o.SubjectURIs)
	o.Boundaries = slices.Clone(o.Boundaries)
	for i := range o.Boundaries {
		o.Boundaries[i].Scope.PublicationSiteKeys = slices.Clone(o.Boundaries[i].Scope.PublicationSiteKeys)
		if o.Boundaries[i].EntryID != nil {
			v := *o.Boundaries[i].EntryID
			o.Boundaries[i].EntryID = &v
		}
	}
	if o.Calendar != nil {
		v := *o.Calendar
		o.Calendar = &v
	}
	return o
}
func NewProjection(operations []Operation, lastSequence int64, protocolVersion int) (*Projection, error) {
	if lastSequence < 0 || lastSequence > MaximumSequence || (protocolVersion != 1 && protocolVersion != 2) {
		return nil, ErrInvalidRecord
	}
	p := &Projection{exact: map[string]Operation{}, scoped: map[string][]scopedOperation{}, lastSequence: lastSequence, actions: map[string]bool{}}
	sequences := map[int64]Operation{}
	actions := map[string]int64{}
	maximum := int64(0)
	for _, input := range operations {
		o := cloneOperation(input)
		if err := ValidateOperation(o); err != nil {
			return nil, err
		}
		if o.Sequence > lastSequence {
			return nil, ErrInvalidRecord
		}
		if other, ok := sequences[o.Sequence]; ok && (other.ActionID != o.ActionID || other.State != o.State || other.ActedAt != o.ActedAt || !reflect.DeepEqual(other.Calendar, o.Calendar)) {
			return nil, ErrConflictingSequence
		}
		if sequence, ok := actions[o.ActionID]; ok && sequence != o.Sequence {
			return nil, ErrConflictingSequence
		}
		sequences[o.Sequence] = o
		actions[o.ActionID] = o.Sequence
		p.actions[o.ActionID] = true
		maximum = max(maximum, o.Sequence)
		p.operations = append(p.operations, o)
		for _, uri := range o.SubjectURIs {
			if p.exact[uri].Sequence < o.Sequence {
				p.exact[uri] = o
			}
		}
		for _, b := range o.Boundaries {
			date, _ := ParseDate(b.CreatedAt)
			p.scoped[b.Scope.AuthorDID] = append(p.scoped[b.Scope.AuthorDID], scopedOperation{b, date, o})
		}
	}
	if protocolVersion == 1 && maximum != lastSequence {
		return nil, ErrIncompleteGeneration
	}
	return p, nil
}
func (p *Projection) LastSequence() int64      { return p.lastSequence }
func (p *Projection) HasAction(id string) bool { return p.actions[id] }
func (p *Projection) Operations() []Operation {
	result := make([]Operation, len(p.operations))
	for i, o := range p.operations {
		result[i] = cloneOperation(o)
	}
	return result
}
func (p *Projection) Resolve(s Subject) Resolution {
	latest := p.exact[s.URI]
	for _, item := range p.scoped[s.AuthorDID] {
		if item.operation.Sequence <= latest.Sequence {
			continue
		}
		keys := item.boundary.Scope.PublicationSiteKeys
		if len(keys) > 0 && (s.PublicationSite == nil || !slices.Contains(keys, *s.PublicationSite)) {
			continue
		}
		if s.CreatedAt.Before(item.date) || (s.CreatedAt.Equal(item.date) && (item.boundary.EntryID == nil || *item.boundary.EntryID >= s.URI)) {
			latest = item.operation
		}
	}
	r := Resolution{IsRead: latest.State == Read, Sequence: latest.Sequence}
	if latest.Sequence > 0 {
		action := latest.ActionID
		r.ActionID = &action
	}
	if r.IsRead {
		at := latest.ActedAt
		r.ReadAt = &at
	}
	return r
}
