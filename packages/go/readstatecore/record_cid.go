package readstatecore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"math"
	"strconv"

	"github.com/ipfs/go-cid"
	"github.com/ipld/go-ipld-prime/codec/dagcbor"
	"github.com/ipld/go-ipld-prime/datamodel"
	cidlink "github.com/ipld/go-ipld-prime/linking/cid"
	"github.com/ipld/go-ipld-prime/node/basicnode"
	"github.com/multiformats/go-multibase"
)

// RecordCID verifies the original JSON record, including fields unknown to the
// current reader. Receipt hashing intentionally uses a narrower value policy.
func RecordCID(data []byte) (string, error) {
	if len(data) > MaximumRecordBytes {
		return "", ErrSizeLimit
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if decoder.Decode(&value) != nil {
		return "", ErrInvalidRecord
	}
	if _, ok := value.(map[string]any); !ok {
		return "", ErrInvalidRecord
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return "", ErrInvalidRecord
	}
	builder := basicnode.Prototype.Any.NewBuilder()
	budget := MaximumRecordBytes
	if err := assembleRecord(builder, value, 0, &budget); err != nil {
		return "", err
	}
	var encoded bytes.Buffer
	if err := dagcbor.Encode(builder.Build(), &encoded); err != nil {
		return "", err
	}
	if encoded.Len() > MaximumRecordBytes {
		return "", ErrSizeLimit
	}
	result, err := (cid.Prefix{Version: 1, Codec: cid.DagCBOR, MhType: 0x12, MhLength: 32}).Sum(encoded.Bytes())
	if err != nil {
		return "", err
	}
	return result.String(), nil
}

func VerifyRecordCID(data []byte, expected string) error {
	if _, err := decodeRecordLink(expected, false); err != nil {
		return err
	}
	actual, err := RecordCID(data)
	if err != nil {
		return err
	}
	if actual != expected {
		return ErrInvalidReference
	}
	return nil
}

func decodeRecordLink(value string, allowRaw bool) (cid.Cid, error) {
	parsed, err := cid.Decode(value)
	if err != nil || len(value) != 59 || len(parsed.Bytes()) != 36 {
		return cid.Undef, ErrInvalidReference
	}
	canonical, err := parsed.StringOfBase(multibase.Base32)
	prefix := parsed.Prefix()
	if err != nil || canonical != value || prefix.Version != 1 || prefix.MhType != 0x12 || prefix.MhLength != 32 || (prefix.Codec != cid.DagCBOR && !(allowRaw && prefix.Codec == cid.Raw)) {
		return cid.Undef, ErrInvalidReference
	}
	return parsed, nil
}

func assembleRecord(node datamodel.NodeAssembler, value any, depth int, budget *int) error {
	if depth > 32 {
		return ErrSizeLimit
	}
	*budget--
	if *budget < 0 {
		return ErrSizeLimit
	}
	switch v := value.(type) {
	case map[string]any:
		if len(v) == 1 {
			if link, ok := v["$link"]; ok {
				text, ok := link.(string)
				if !ok {
					return ErrInvalidRecord
				}
				parsed, err := decodeRecordLink(text, true)
				if err != nil {
					return err
				}
				return node.AssignLink(cidlink.Link{Cid: parsed})
			}
			if raw, ok := v["$bytes"]; ok {
				text, ok := raw.(string)
				if !ok {
					return ErrInvalidRecord
				}
				binary, err := base64.StdEncoding.Strict().DecodeString(text)
				if err != nil {
					return ErrInvalidRecord
				}
				*budget -= len(binary)
				if *budget < 0 {
					return ErrSizeLimit
				}
				return node.AssignBytes(binary)
			}
		}
		if len(v) > *budget/2 {
			return ErrSizeLimit
		}
		object, err := node.BeginMap(int64(len(v)))
		if err != nil {
			return err
		}
		for key, child := range v {
			if err := assembleCanonical(object.AssembleKey(), key, depth+1, budget); err != nil {
				return err
			}
			if err := assembleRecord(object.AssembleValue(), child, depth+1, budget); err != nil {
				return err
			}
		}
		return object.Finish()
	case []any:
		if len(v) > *budget {
			return ErrSizeLimit
		}
		list, err := node.BeginList(int64(len(v)))
		if err != nil {
			return err
		}
		for _, child := range v {
			if err := assembleRecord(list.AssembleValue(), child, depth+1, budget); err != nil {
				return err
			}
		}
		return list.Finish()
	case json.Number:
		if integer, err := v.Int64(); err == nil {
			return assignCanonicalInt(node, integer)
		}
		// ATProto JSON can encode an integral number as 1.0 or 1e3.
		number, err := strconv.ParseFloat(string(v), 64)
		if err != nil || math.IsNaN(number) || math.IsInf(number, 0) || math.Trunc(number) != number || math.Abs(number) > float64(MaximumSequence) {
			return ErrInvalidRecord
		}
		return node.AssignInt(int64(number))
	default:
		return assembleCanonical(node, value, depth, budget)
	}
}
