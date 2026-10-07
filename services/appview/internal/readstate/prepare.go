package readstate

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
	"github.com/stygian-tech/the-social-wire/packages/go/readagecore"
	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

var errSelectionTooLarge = errors.New("select a smaller read scope")

func (a Routes) prepare(w http.ResponseWriter, req *http.Request) {
	did, ok := viewer(w, req)
	if !ok {
		return
	}
	var body struct {
		Scope              appviewcore.ReadScopeSelector `json:"scope"`
		Before             *string                       `json:"before"`
		TimeZone           *string                       `json:"timeZone"`
		ReferenceDate      *string                       `json:"referenceDate"`
		PreviewSubjectURIs *[]string                     `json:"previewSubjectUris"`
	}
	if !decode(w, req, &body) {
		return
	}
	if body.Scope.Kind != "publication" && body.Scope.Kind != "folder" && body.Scope.Kind != "subscribed" && body.Scope.Kind != "following" {
		respondError(w, 400, "InvalidRequest", "Unknown read-state scope")
		return
	}
	if body.PreviewSubjectURIs != nil {
		if len(*body.PreviewSubjectURIs) > 1000 {
			respondError(w, 400, "InvalidRequest", "Preview supports at most 1000 cached subject IDs")
			return
		}
		for _, uri := range *body.PreviewSubjectURIs {
			if uri == "" || len(uri) > 2048 {
				respondError(w, 400, "InvalidRequest", "Invalid preview subject ID")
				return
			}
		}
	}
	now := time.Now()
	var cutoff time.Time
	var calendar *r.CalendarSelection
	if body.Before != nil {
		var err error
		cutoff, err = readagecore.Cutoff(*body.Before, now)
		if err != nil || body.TimeZone == nil || body.ReferenceDate == nil {
			respondError(w, 400, "InvalidRequest", "Age selection requires before, timeZone and referenceDate")
			return
		}
		if _, err := readagecore.Location(*body.TimeZone); err != nil {
			respondError(w, 400, "InvalidRequest", "Invalid IANA time zone")
			return
		}
		calendar = &r.CalendarSelection{Cutoff: readagecore.Timestamp(cutoff), TimeZone: *body.TimeZone, ReferenceDate: *body.ReferenceDate}
		if err := r.ValidateOperation(r.Operation{ActionID: "calendar-validation", Sequence: 1, State: r.Read, Selection: r.Exact, ActedAt: readagecore.Timestamp(now), SubjectURIs: []string{"validation"}, Calendar: calendar}); err != nil {
			finish(w, nil, err)
			return
		}
	}
	prior, err := a.Store.Status(req.Context(), did)
	if err != nil {
		finish(w, nil, err)
		return
	}
	auth, _ := gatewaycore.AuthContextFrom(req.Context())
	scopes, err := a.ResolveScopes(req.Context(), auth, body.Scope)
	if err != nil {
		finish(w, nil, err)
		return
	}
	selection := preparedSelection{ActedAt: readagecore.Timestamp(now), LegacyRevision: prior.LegacyRevision, ManifestCID: prior.ManifestCID}
	if body.Before != nil {
		ids := []string{}
		scanned, bytes := 0, 0
		ctx, cancel := context.WithTimeout(req.Context(), 30*time.Second)
		defer cancel()
		err = (appviewcore.ContentReader{DB: a.DB}).WalkUnread(ctx, did, scopes, 100, now, func(entries []appviewcore.UnreadMutationEntry) error {
			scanned += len(entries)
			for _, entry := range entries {
				if entry.PublishedAt.Before(cutoff) {
					ids = append(ids, entry.EntryID)
					bytes += len(entry.EntryID) + 4
				}
			}
			if len(ids) > 100000 || scanned > 250000 || bytes > 8*1024*1024 {
				return errSelectionTooLarge
			}
			return nil
		})
		if errors.Is(err, errSelectionTooLarge) || errors.Is(err, context.DeadlineExceeded) {
			respondError(w, 413, "ContentTooLarge", "Select a smaller read scope")
			return
		}
		if err != nil {
			finish(w, nil, err)
			return
		}
		selection.Selection, selection.SubjectURIs, selection.Calendar = r.Exact, &ids, calendar
	} else {
		canonical := []r.Scope{}
		for _, scope := range scopes {
			keys := appviewcore.PublicationSiteKeys(scope)
			if len(keys) == 0 && (scope.PublicationATURI != nil || len(scope.PublicationScopeATURIs) > 0 || len(scope.PublicationSiteURLs) > 0) {
				finish(w, nil, pdsreadstatecore.ErrLegacyScopeUnavailable)
				return
			}
			canonical = append(canonical, r.Scope{PublicationID: scope.PublicationID, AuthorDID: scope.AuthorDID, PublicationSiteKeys: keys})
		}
		boundaries, err := a.Store.PrepareBoundaries(req.Context(), did, canonical, now)
		if err != nil {
			finish(w, nil, err)
			return
		}
		selection.Selection, selection.Boundaries = r.Boundaries, &boundaries
		if body.PreviewSubjectURIs != nil {
			preview, err := a.Store.PreviewBoundaries(req.Context(), boundaries, *body.PreviewSubjectURIs)
			if err != nil {
				finish(w, nil, err)
				return
			}
			selection.PreviewSubjectURIs = &preview
		}
	}
	current, err := a.Store.Status(req.Context(), did)
	if err != nil {
		finish(w, nil, err)
		return
	}
	if current.LegacyRevision != prior.LegacyRevision || !sameOptionalString(current.ManifestCID, prior.ManifestCID) {
		respondError(w, 409, "ReadStateChanged", "Read state changed during selection; refresh and retry")
		return
	}
	finish(w, selection, nil)
}
func sameOptionalString(a, b *string) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}
