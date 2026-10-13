package topicreadcore

import (
	"bytes"
	"encoding/json"
	"regexp"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

var leanSnapshotFingerprint = regexp.MustCompile(`^[a-f0-9]{64}$`)

// The first lean-source adapter wrote both required display collections as null
// before strict snapshot decoding rejected the response. Read those task-created
// rows in memory without rewriting their canonical identity/order. Every other
// contract field still passes the original strict decoder.
func decodeSportsSnapshot(raw []byte, candidates *[]sportscore.RankCandidate) error {
	if err := corpuscore.DecodeContract(raw, candidates); err == nil {
		return nil
	}
	var rows []json.RawMessage
	if json.Unmarshal(raw, &rows) != nil {
		return corpuscore.ErrContractMismatch
	}
	changed := false
	for i, row := range rows {
		var candidate map[string]json.RawMessage
		if json.Unmarshal(row, &candidate) != nil {
			continue
		}
		var fingerprint string
		if json.Unmarshal(candidate["presentationFingerprint"], &fingerprint) != nil || !leanSnapshotFingerprint.MatchString(fingerprint) {
			continue
		}
		var item map[string]json.RawMessage
		if json.Unmarshal(candidate["item"], &item) != nil {
			continue
		}
		if !bytes.Equal(bytes.TrimSpace(item["reasons"]), []byte("null")) || !bytes.Equal(bytes.TrimSpace(item["provenance"]), []byte("null")) {
			continue
		}
		item["reasons"] = json.RawMessage("[]")
		item["provenance"] = json.RawMessage("[]")
		encoded, err := json.Marshal(item)
		if err != nil {
			return corpuscore.ErrContractMismatch
		}
		candidate["item"] = encoded
		rows[i], err = json.Marshal(candidate)
		if err != nil {
			return corpuscore.ErrContractMismatch
		}
		changed = true
	}
	if !changed {
		return corpuscore.ErrContractMismatch
	}
	encoded, err := json.Marshal(rows)
	if err != nil {
		return corpuscore.ErrContractMismatch
	}
	return corpuscore.DecodeContract(encoded, candidates)
}
