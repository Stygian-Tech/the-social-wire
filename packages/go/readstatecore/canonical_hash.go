package readstatecore

// Assembles the restricted receipt value model into IPLD nodes and delegates canonical
// DAG-CBOR ordering/encoding to go-ipld-prime. Construction and output are bounded;
// floats, bytes, links, unsupported types, unsafe integers, and invalid UTF-8 are
// rejected.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"unicode/utf8"

	"github.com/ipld/go-ipld-prime/codec/dagcbor"
	"github.com/ipld/go-ipld-prime/datamodel"
	"github.com/ipld/go-ipld-prime/node/basicnode"
)

// CanonicalBytes uses the IPLD DAG-CBOR codec, retaining the narrower receipt
// value policy: no floats, links, bytes, unsafe integers, or excessive nesting.
func CanonicalBytes(value any) ([]byte, error) {
	builder := basicnode.Prototype.Any.NewBuilder()
	budget := 16 * 1024 * 1024
	if err := assembleCanonical(builder, value, 0, &budget); err != nil {
		return nil, err
	}
	var output canonicalBuffer
	if err := dagcbor.Encode(builder.Build(), &output); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func assembleCanonical(node datamodel.NodeAssembler, value any, depth int, budget *int) error {
	if depth > 32 {
		return ErrSizeLimit
	}
	// Bound construction as well as encoded output, before allocating IPLD nodes.
	*budget -= 1
	if *budget < 0 {
		return ErrSizeLimit
	}
	switch typedValue := value.(type) {
	case nil:
		return node.AssignNull()
	case bool:
		return node.AssignBool(typedValue)
	case int:
		return assignCanonicalInt(node, int64(typedValue))
	case int64:
		return assignCanonicalInt(node, typedValue)
	case json.Number:
		count, err := typedValue.Int64()
		if err != nil {
			return ErrInvalidRecord
		}
		return assignCanonicalInt(node, count)
	case string:
		if !utf8.ValidString(typedValue) {
			return ErrInvalidRecord
		}
		*budget -= len(typedValue)
		if *budget < 0 {
			return ErrSizeLimit
		}
		return node.AssignString(typedValue)
	case []any:
		if len(typedValue) > *budget {
			return ErrSizeLimit
		}
		list, err := node.BeginList(int64(len(typedValue)))
		if err != nil {
			return err
		}
		for _, childValue := range typedValue {
			if err := assembleCanonical(list.AssembleValue(), childValue, depth+1, budget); err != nil {
				return err
			}
		}
		return list.Finish()
	case map[string]any:
		if len(typedValue) > *budget/2 {
			return ErrSizeLimit
		}
		object, err := node.BeginMap(int64(len(typedValue)))
		if err != nil {
			return err
		}
		for key, childValue := range typedValue {
			if err := assembleCanonical(object.AssembleKey(), key, depth+1, budget); err != nil {
				return err
			}
			if err := assembleCanonical(object.AssembleValue(), childValue, depth+1, budget); err != nil {
				return err
			}
		}
		return object.Finish()
	default:
		return fmt.Errorf("%w: unsupported canonical value %T", ErrInvalidRecord, value)
	}
}

func assignCanonicalInt(node datamodel.NodeAssembler, value int64) error {
	if value < -MaximumSequence || value > MaximumSequence {
		return ErrInvalidRecord
	}
	return node.AssignInt(value)
}

// CanonicalHash returns lowercase SHA-256 of the restricted canonical DAG-CBOR encoding.
func CanonicalHash(value any) (string, error) {
	data, err := CanonicalBytes(value)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

// CanonicalJSONHash decodes exactly one JSON value with exact integers, then hashes its
// canonical DAG-CBOR representation.
func CanonicalJSONHash(data []byte) (string, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return "", err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return "", ErrInvalidRecord
	}
	return CanonicalHash(value)
}
