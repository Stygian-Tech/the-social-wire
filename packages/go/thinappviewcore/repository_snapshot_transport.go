package thinappviewcore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/jcalabro/atmos"
	"github.com/jcalabro/atmos/car"
	"github.com/jcalabro/atmos/cbor"
	"github.com/jcalabro/atmos/mst"
	"io"
	"net/http"
	"net/url"
	"time"
)

type snapshotRead struct {
	reader                  RepositorySnapshotReader
	getter                  PublicGetter
	bytes, requests, blocks int
	store                   *mst.MemBlockStore
}

func snapshotError(category string) error { return errors.New("repository snapshot " + category) }
func boundedSnapshotLimit(value, ceiling int) int {
	if value <= 0 || value > ceiling {
		return ceiling
	}
	return value
}

func (s *snapshotRead) get(ctx context.Context, target, accept string, limit int) ([]byte, error) {
	for retry := 0; retry <= 2; retry++ {
		if ctx.Err() != nil {
			return nil, snapshotError("cancelled")
		}
		s.requests++
		if s.requests > s.reader.MaximumRequests {
			return nil, snapshotError("request limit exceeded")
		}
		request, cancel := context.WithTimeout(ctx, 15*time.Second)
		status, headers, body, err := s.getter.Get(request, target, http.Header{"Accept": {accept}}, limit, 0)
		cancel()
		if err != nil {
			return nil, snapshotError("request failed")
		}
		s.bytes += len(body)
		if len(body) > limit || s.bytes > s.reader.MaximumBytes {
			return nil, snapshotError("byte limit exceeded")
		}
		if status == 429 && retry < 2 {
			delay := time.Second
			if parsed, err := time.ParseDuration(headers.Get("Retry-After") + "s"); err == nil && parsed >= 0 {
				delay = min(parsed, 5*time.Second)
			}
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return nil, snapshotError("cancelled")
			case <-timer.C:
			}
			continue
		}
		if status != 200 {
			return nil, snapshotError("upstream unavailable")
		}
		return body, nil
	}
	return nil, snapshotError("upstream unavailable")
}
func (s *snapshotRead) latest(ctx context.Context, base, did string) (cbor.CID, string, error) {
	body, err := s.get(ctx, base+"/xrpc/com.atproto.sync.getLatestCommit?"+url.Values{"did": {did}}.Encode(), "application/json", 65536)
	if err != nil {
		return cbor.CID{}, "", err
	}
	var latest struct {
		CID string `json:"cid"`
		Rev string `json:"rev"`
	}
	if json.Unmarshal(body, &latest) != nil {
		return cbor.CID{}, "", snapshotError("invalid latest commit")
	}
	cid, err := cbor.ParseCIDString(latest.CID)
	if err != nil || cid.Codec() != cbor.CodecDagCBOR {
		return cbor.CID{}, "", snapshotError("invalid latest commit")
	}
	if _, err := atmos.ParseTID(latest.Rev); err != nil {
		return cbor.CID{}, "", snapshotError("invalid revision")
	}
	return cid, latest.Rev, nil
}
func (s *snapshotRead) active(ctx context.Context, base, did string) error {
	body, err := s.get(ctx, base+"/xrpc/com.atproto.sync.getRepoStatus?"+url.Values{"did": {did}}.Encode(), "application/json", 65536)
	if err != nil {
		return err
	}
	var status struct {
		DID    string `json:"did"`
		Active bool   `json:"active"`
	}
	if json.Unmarshal(body, &status) != nil || status.DID != did || !status.Active {
		return snapshotError("inactive repository")
	}
	return nil
}
func (s *snapshotRead) fetchBlocks(ctx context.Context, base, did string, cids []cbor.CID) error {
	requested := map[string]bool{}
	params := url.Values{"did": {did}}
	for _, cid := range cids {
		if cid.Codec() != cbor.CodecDagCBOR {
			return snapshotError("invalid block CID")
		}
		if _, err := s.store.GetBlock(cid); err == nil {
			continue
		}
		if !requested[cid.String()] {
			requested[cid.String()] = true
			params.Add("cids", cid.String())
		}
	}
	if len(requested) == 0 {
		return nil
	}
	body, err := s.get(ctx, base+"/xrpc/com.atproto.sync.getBlocks?"+params.Encode(), "application/vnd.ipld.car", 8*1024*1024)
	if err != nil {
		return err
	}
	reader, err := car.NewReader(bytes.NewReader(body))
	if err != nil {
		return snapshotError("invalid CAR")
	}
	for {
		block, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return snapshotError("invalid CAR block")
		}
		if !requested[block.CID.String()] {
			return snapshotError("unrequested CAR block")
		}
		delete(requested, block.CID.String())
		s.blocks++
		if s.blocks > s.reader.MaximumBlocks {
			return snapshotError("block limit exceeded")
		}
		if err := s.store.PutBlock(block.CID, block.Data); err != nil {
			return snapshotError("block storage failed")
		}
	}
	if len(requested) != 0 {
		return snapshotError("missing requested block")
	}
	return nil
}
