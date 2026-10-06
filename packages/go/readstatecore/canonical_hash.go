package readstatecore

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
	switch x := value.(type) {
	case nil:
		return node.AssignNull()
	case bool:
		return node.AssignBool(x)
	case int:
		return assignCanonicalInt(node, int64(x))
	case int64:
		return assignCanonicalInt(node, x)
	case json.Number:
		n, err := x.Int64()
		if err != nil {
			return ErrInvalidRecord
		}
		return assignCanonicalInt(node, n)
	case string:
		if !utf8.ValidString(x) {
			return ErrInvalidRecord
		}
		*budget -= len(x)
		if *budget < 0 {
			return ErrSizeLimit
		}
		return node.AssignString(x)
	case []any:
		if len(x) > *budget {
			return ErrSizeLimit
		}
		list, err := node.BeginList(int64(len(x)))
		if err != nil {
			return err
		}
		for _, v := range x {
			if err := assembleCanonical(list.AssembleValue(), v, depth+1, budget); err != nil {
				return err
			}
		}
		return list.Finish()
	case map[string]any:
		if len(x) > *budget/2 {
			return ErrSizeLimit
		}
		object, err := node.BeginMap(int64(len(x)))
		if err != nil {
			return err
		}
		for k, v := range x {
			if err := assembleCanonical(object.AssembleKey(), k, depth+1, budget); err != nil {
				return err
			}
			if err := assembleCanonical(object.AssembleValue(), v, depth+1, budget); err != nil {
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

func CanonicalHash(value any) (string, error) {
	data, e := CanonicalBytes(value)
	if e != nil {
		return "", e
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}
func CanonicalJSONHash(data []byte) (string, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return "", err
	}
	var trailing any
	if err := d.Decode(&trailing); err != io.EOF {
		return "", ErrInvalidRecord
	}
	return CanonicalHash(v)
}
