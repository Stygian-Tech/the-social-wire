package listcore

import (
	"context"
	"encoding/json"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type RecordRead struct {
	Records  []gatewaycore.RepoRecord
	Complete bool
}
type PublicationRead struct {
	Details *Publication
	SiteURL *string
}
type Reader interface {
	Records(context.Context, string, string) (RecordRead, error)
	Record(context.Context, Identity) (json.RawMessage, error)
	Publication(context.Context, string) (*PublicationRead, error)
	CreatorDID(context.Context, string) (string, error)
}
type RepoReader struct{ Repo *gatewaycore.RepoClient }

func (r RepoReader) Records(ctx context.Context, did, collection string) (RecordRead, error) {
	result := RecordRead{Records: []gatewaycore.RepoRecord{}, Complete: true}
	cursor := ""
	for range 20 {
		page, err := r.Repo.ListRecords(ctx, did, collection, cursor, 100, true)
		if err != nil {
			return RecordRead{}, err
		}
		for _, record := range page.Records {
			if record.Value != nil {
				result.Records = append(result.Records, record)
			}
		}
		cursor = page.Cursor
		if cursor == "" {
			return result, nil
		}
	}
	result.Complete = false
	return result, nil
}
func (r RepoReader) Record(ctx context.Context, identity Identity) (json.RawMessage, error) {
	record, err := r.Repo.GetRecord(ctx, identity.DID, Collection, identity.RKey, "")
	if err != nil || record == nil {
		return nil, err
	}
	return json.Marshal(record.Value)
}
func (r RepoReader) CreatorDID(ctx context.Context, input string) (string, error) {
	return r.Repo.ResolveDID(ctx, input)
}

func (r RepoReader) Publication(ctx context.Context, uri string) (*PublicationRead, error) {
	did, ok := PublicationIdentity(uri)
	if !ok {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	parts := splitRecordURI(uri)
	record, err := r.Repo.GetRecord(ctx, did, "site.standard.publication", parts[2], "")
	if err != nil || record == nil {
		return nil, err
	}
	return r.publicationDetails(ctx, record, did, uri, parts[2])
}
