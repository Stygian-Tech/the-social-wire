package readstatecore

import "encoding/json"

// V2Chunk is one immutable page in exactly one of the three manifest chains.
type V2Chunk struct {
	Kind      string
	Fragments []V2Fragment
	Devices   []DeviceReceipt
	Legacy    []LegacyReceipt
	Previous  *Reference
}

// DecodeV2Chunk validates closed nested shapes before retaining typed selectors.
func DecodeV2Chunk(data []byte, viewer string) (V2Chunk, error) {
	var chunk V2Chunk
	if len(data) > MaximumRecordBytes {
		return chunk, ErrSizeLimit
	}
	var header struct {
		Type     string     `json:"$type"`
		Version  int        `json:"version"`
		Kind     string     `json:"kind"`
		Previous *Reference `json:"previous"`
	}
	if json.Unmarshal(data, &header) != nil || header.Type != ChunkCollection || header.Version != 2 {
		return chunk, ErrInvalidRecord
	}
	key := "receipts"
	if header.Kind == "state" {
		key = "fragments"
	} else if header.Kind != "devices" && header.Kind != "legacyReceipts" {
		return chunk, ErrInvalidRecord
	}
	object, err := recordObject(data, []string{"$type", "version", "kind", key, "previous"}, []string{"$type", "version", "kind", key})
	if err != nil {
		return chunk, err
	}
	if err := closedReference(object["previous"]); err != nil {
		return chunk, err
	}
	chunk.Kind, chunk.Previous = header.Kind, header.Previous
	if chunk.Previous != nil {
		if err := ValidateReference(*chunk.Previous, viewer); err != nil {
			return chunk, err
		}
	}
	var entries []json.RawMessage
	if json.Unmarshal(object[key], &entries) != nil || len(entries) < 1 || len(entries) > 128 {
		return chunk, ErrInvalidRecord
	}
	for _, entry := range entries {
		switch chunk.Kind {
		case "state":
			var fragment V2Fragment
			if err := json.Unmarshal(entry, &fragment); err != nil {
				return chunk, ErrInvalidRecord
			}
			chunk.Fragments = append(chunk.Fragments, fragment)
		case "devices":
			if _, err := recordObject(entry, []string{"deviceId", "committedCounter", "prefixHash"}, []string{"deviceId", "committedCounter", "prefixHash"}); err != nil {
				return chunk, err
			}
			var receipt DeviceReceipt
			if json.Unmarshal(entry, &receipt) != nil || receipt.Validate() != nil {
				return chunk, ErrInvalidRecord
			}
			chunk.Devices = append(chunk.Devices, receipt)
		case "legacyReceipts":
			if _, err := recordObject(entry, []string{"actionId", "originalSequence", "originalIntentHash"}, []string{"actionId", "originalSequence", "originalIntentHash"}); err != nil {
				return chunk, err
			}
			var receipt LegacyReceipt
			if json.Unmarshal(entry, &receipt) != nil || receipt.Validate() != nil {
				return chunk, ErrInvalidRecord
			}
			chunk.Legacy = append(chunk.Legacy, receipt)
		}
	}
	return chunk, nil
}
