package topicreadcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
)

func decodeRequired(data []byte, target any, keys ...string) error {
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		return errors.New("invalid Circle cache object")
	}
	for _, key := range keys {
		value, exists := raw[key]
		if !exists || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return errors.New("incomplete Circle cache object")
		}
	}
	return json.Unmarshal(data, target)
}
func (g *cacheGraph) UnmarshalJSON(data []byte) error {
	type value cacheGraph
	var v value
	if err := decodeRequired(data, &v, "snapshotID", "viewerDID", "directMembers", "oneHopMembers", "directCandidateCount", "oneHopCandidateCount", "generatedAt"); err != nil {
		return err
	}
	if !validUUID(v.SnapshotID) || math.IsNaN(v.GeneratedAt) || math.IsInf(v.GeneratedAt, 0) {
		return errors.New("invalid Circle snapshot")
	}
	*g = cacheGraph(v)
	return nil
}
func (m *cacheMember) UnmarshalJSON(data []byte) error {
	type value cacheMember
	var v value
	if err := decodeRequired(data, &v, "actorDID", "depth", "pathCount"); err != nil {
		return err
	}
	if v.Depth != 1 && v.Depth != 2 {
		return errors.New("invalid Circle depth")
	}
	*m = cacheMember(v)
	return nil
}
func (e *graphEntry) UnmarshalJSON(data []byte) error {
	type value graphEntry
	var v value
	if err := decodeRequired(data, &v, "exclusions", "snapshot"); err != nil {
		return err
	}
	*e = graphEntry(v)
	return nil
}
func (e *editionEntry) UnmarshalJSON(data []byte) error {
	type value editionEntry
	var v value
	if err := decodeRequired(data, &v, "snapshotID", "generationID", "language", "hiddenStoryIDs", "payload"); err != nil {
		return err
	}
	if !validUUID(v.SnapshotID) {
		return errors.New("invalid Circle edition snapshot")
	}
	*e = editionEntry(v)
	return nil
}
