package thinappviewcore

import (
	"bytes"
	"context"
	"github.com/jcalabro/atmos"
	"github.com/jcalabro/atmos/cbor"
	"github.com/jcalabro/atmos/mst"
	"github.com/jcalabro/atmos/repo"
	"strings"
	"time"
)

func (r RepositorySnapshotReader) Read(ctx context.Context, did string, collections []string) (RepositorySnapshot, error) {
	var empty RepositorySnapshot
	if r.PDS == nil {
		return empty, snapshotError("configuration unavailable")
	}
	targets := map[string]bool{}
	for _, collection := range collections {
		if _, err := atmos.ParseNSID(collection); err != nil {
			return empty, snapshotError("invalid collection")
		}
		targets[collection] = true
	}
	if len(targets) == 0 {
		return empty, snapshotError("invalid collection")
	}
	r.MaximumBytes = boundedSnapshotLimit(r.MaximumBytes, 32*1024*1024)
	r.MaximumBlocks = boundedSnapshotLimit(r.MaximumBlocks, 100000)
	r.MaximumRecords = boundedSnapshotLimit(r.MaximumRecords, 20000)
	r.MaximumRequests = boundedSnapshotLimit(r.MaximumRequests, 1024)
	r.MaximumDepth = boundedSnapshotLimit(r.MaximumDepth, 64)
	if r.Timeout <= 0 || r.Timeout > 2*time.Minute {
		r.Timeout = 2 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()
	getter := r.PDS.HTTP
	if getter == nil {
		getter = PublicHTTP{}
	}
	s := &snapshotRead{reader: r, getter: getter, store: mst.NewMemBlockStore()}
	base, key, err := s.identity(ctx, did)
	if err != nil {
		return empty, err
	}
	if err := s.active(ctx, base, did); err != nil {
		return empty, err
	}
	commitCID, revision, err := s.latest(ctx, base, did)
	if err != nil {
		return empty, err
	}
	if err := s.fetchBlocks(ctx, base, did, []cbor.CID{commitCID}); err != nil {
		return empty, err
	}
	raw, err := s.store.GetBlock(commitCID)
	if err != nil {
		return empty, snapshotError("missing commit")
	}
	commit, err := repo.DecodeCommitCBOR(raw)
	if err != nil || commit.DID != did || commit.Version != 3 || commit.Rev != revision {
		return empty, snapshotError("invalid commit")
	}
	canonical, err := commit.EncodeCBOR()
	if err != nil || !bytes.Equal(raw, canonical) || commit.VerifySignature(key) != nil {
		return empty, snapshotError("invalid commit signature")
	}
	tid, err := atmos.ParseTID(revision)
	now := time.Now()
	if r.Now != nil {
		now = r.Now()
	}
	if err != nil || tid.Time().After(now.Add(5*time.Minute)) {
		return empty, snapshotError("invalid revision")
	}
	if err := s.loadTree(ctx, base, did, commit.Data); err != nil {
		return empty, err
	}
	type leaf struct {
		path string
		cid  cbor.CID
	}
	leaves := []leaf{}
	canonicalTree := mst.NewTree(mst.NewMemBlockStore())
	last := ""
	total := 0
	err = mst.LoadTree(s.store, commit.Data).Walk(func(path string, value cbor.CID) error {
		if ctx.Err() != nil {
			return snapshotError("cancelled")
		}
		collection, rkey, ok := strings.Cut(path, "/")
		if !ok || path <= last {
			return snapshotError("invalid tree ordering")
		}
		if _, err := atmos.ParseNSID(collection); err != nil {
			return snapshotError("invalid record path")
		}
		if _, err := atmos.ParseRecordKey(rkey); err != nil {
			return snapshotError("invalid record path")
		}
		if err := canonicalTree.Insert(path, value); err != nil {
			return snapshotError("invalid canonical tree")
		}
		last = path
		total++
		if total > r.MaximumBlocks {
			return snapshotError("record limit exceeded")
		}
		if targets[collection] {
			leaves = append(leaves, leaf{path, value})
			if len(leaves) > r.MaximumRecords {
				return snapshotError("record limit exceeded")
			}
		}
		return nil
	})
	if err != nil {
		return empty, snapshotError("invalid or incomplete tree")
	}
	// Rebuilding the canonical MST also validates cross-node ranges and key
	// heights, which a successful ordered walk alone does not establish.
	rebuilt, err := canonicalTree.RootCID()
	if err != nil || !rebuilt.Equal(commit.Data) {
		return empty, snapshotError("noncanonical tree")
	}
	for start := 0; start < len(leaves); start += 50 {
		needed := []cbor.CID{}
		for _, leaf := range leaves[start:min(start+50, len(leaves))] {
			needed = append(needed, leaf.cid)
		}
		if err := s.fetchBlocks(ctx, base, did, needed); err != nil {
			return empty, err
		}
	}
	result := RepositorySnapshot{PDSBase: base, CommitCID: commitCID.String(), Revision: revision, Records: []RepositorySnapshotRecord{}}
	for _, leaf := range leaves {
		raw, err := s.store.GetBlock(leaf.cid)
		if err != nil {
			return empty, snapshotError("missing record block")
		}
		value, err := cbor.Unmarshal(raw)
		if err != nil {
			return empty, snapshotError("invalid record block")
		}
		if _, ok := value.(map[string]any); !ok {
			return empty, snapshotError("invalid record object")
		}
		encoded, err := cbor.Marshal(value)
		if err != nil || !bytes.Equal(raw, encoded) {
			return empty, snapshotError("noncanonical record")
		}
		jsonValue, err := cbor.ToJSON(value)
		if err != nil {
			return empty, snapshotError("invalid record JSON")
		}
		result.Records = append(result.Records, RepositorySnapshotRecord{URI: "at://" + did + "/" + leaf.path, CID: leaf.cid.String(), Value: jsonValue})
	}
	finalBase, finalKey, err := s.identity(ctx, did)
	if err != nil {
		return empty, err
	}
	if finalBase != base || !key.Equal(finalKey) {
		return empty, snapshotError("identity changed")
	}
	if err := s.active(ctx, base, did); err != nil {
		return empty, err
	}
	finalCID, finalRev, err := s.latest(ctx, base, did)
	if err != nil {
		return empty, err
	}
	if !finalCID.Equal(commitCID) || finalRev != revision {
		return empty, snapshotError("commit changed")
	}
	if ctx.Err() != nil {
		return empty, snapshotError("cancelled")
	}
	return result, nil
}

func (s *snapshotRead) loadTree(ctx context.Context, base, did string, root cbor.CID) error {
	type node struct {
		cid   cbor.CID
		depth int
	}
	queue := []node{{root, 0}}
	seen := map[string]bool{root.String(): true}
	enqueue := func(cid cbor.CID, depth int) error {
		// Canonical MST nodes contain absolute key ranges and form a tree.
		// Reject graph sharing before a recursive library walk can expand it.
		if seen[cid.String()] {
			return snapshotError("repeated tree reference")
		}
		if depth > s.reader.MaximumDepth {
			return snapshotError("depth limit exceeded")
		}
		seen[cid.String()] = true
		queue = append(queue, node{cid, depth})
		if len(seen) > s.reader.MaximumBlocks {
			return snapshotError("block limit exceeded")
		}
		return nil
	}
	for len(queue) > 0 {
		if ctx.Err() != nil {
			return snapshotError("cancelled")
		}
		batch := queue[:min(50, len(queue))]
		queue = queue[len(batch):]
		needed := []cbor.CID{}
		for _, item := range batch {
			if item.depth > s.reader.MaximumDepth {
				return snapshotError("depth limit exceeded")
			}
			needed = append(needed, item.cid)
		}
		if err := s.fetchBlocks(ctx, base, did, needed); err != nil {
			return err
		}
		for _, item := range batch {
			raw, err := s.store.GetBlock(item.cid)
			if err != nil {
				return snapshotError("missing tree block")
			}
			decoded, err := mst.DecodeNodeData(raw)
			if err != nil {
				return snapshotError("invalid tree block")
			}
			if decoded.Left.HasVal() {
				if err := enqueue(decoded.Left.Val(), item.depth+1); err != nil {
					return err
				}
			}
			for _, entry := range decoded.Entries {
				if entry.Right.HasVal() {
					if err := enqueue(entry.Right.Val(), item.depth+1); err != nil {
						return err
					}
				}
			}
			if len(queue) > s.reader.MaximumBlocks {
				return snapshotError("block limit exceeded")
			}
		}
	}
	return nil
}
