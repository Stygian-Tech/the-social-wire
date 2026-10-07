package thinappviewcore

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"time"
)

type SelectionMutation struct {
	Topic, ViewerDID, RecordKey, RepoRev string
	Value, Reference                     *string
	EventAt                              time.Time
}

func ParseSelectionMutation(topic, viewer, key, operation string, record map[string]any, at time.Time, rev string) *SelectionMutation {
	if !strings.HasPrefix(viewer, "did:") || len(key) != 64 {
		return nil
	}
	for _, c := range key {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return nil
		}
	}
	if topic != "finance" && topic != "sports" {
		return nil
	}
	result := &SelectionMutation{Topic: topic, ViewerDID: viewer, RecordKey: key, EventAt: at, RepoRev: rev}
	if operation == "delete" {
		return result
	}
	if operation != "create" && operation != "update" {
		return nil
	}
	if record["$type"] != "app.thesocialwire."+topic+".selection" {
		return nil
	}
	field := "kind"
	if topic == "sports" {
		field = "action"
	}
	value, ok := record[field].(string)
	if !ok {
		return nil
	}
	if topic == "finance" && value != "instrument" && value != "sector" || topic == "sports" && value != "follow" && value != "mute" {
		return nil
	}
	ref, ok := record["reference"].(string)
	if !ok || len(ref) == 0 || len(ref) > 128 {
		return nil
	}
	identity := ref
	if topic == "finance" {
		identity = value + ":" + ref
	}
	hash := sha256.Sum256([]byte(identity))
	if hex.EncodeToString(hash[:]) != key {
		return nil
	}
	result.Value = &value
	result.Reference = &ref
	return result
}
