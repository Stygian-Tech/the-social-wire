package wireworkercore

import (
	"database/sql"
	"testing"
)

func TestStandardRecordSnapshotsPreserveOriginalActivityAndOrdering(t *testing.T) {
	str := func(v string) sql.NullString { return sql.NullString{String: v, Valid: true} }
	commit := StandardRecordFence{Kind: "commit", Operation: "create", Host: "jetstream.example", Cursor: "us", Sequence: 100, Revision: str("2222222222222"), CID: str("same")}
	snapshot := commit
	snapshot.Kind = "snapshot"
	snapshot.Sequence = 10000
	snapshot.Revision = str("3333333333333")
	if order := snapshot.Compare(commit); order != RecordSame {
		t.Fatalf("same content snapshot gained activity: %s", order)
	}
	observed := commit.Observing(snapshot.Revision)
	deletion := commit
	deletion.Operation = "delete"
	deletion.Revision = str("2222222222223")
	deletion.Sequence = 200
	if order := deletion.Compare(observed); order != RecordOlder {
		t.Fatalf("stale delete bypassed watermark: %s", order)
	}
	deletion.Revision = str("4444444444444")
	if order := deletion.Compare(observed); order != RecordNewer {
		t.Fatalf("authoritative delete not accepted: %s", order)
	}
	snapshot.CID = str("different")
	snapshot.Revision = commit.Revision
	if snapshot.Compare(commit) != RecordConflict {
		t.Fatal("different same-revision content did not conflict")
	}
	unknown := commit
	unknown.Revision = sql.NullString{}
	unknown.Host = "other.example"
	unknown.Sequence = 99999
	if unknown.Compare(commit) != RecordConflict {
		t.Fatal("cross-host sequence used as clock")
	}
}
