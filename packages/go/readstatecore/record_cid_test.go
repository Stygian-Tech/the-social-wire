package readstatecore

import (
	"crypto/sha256"
	"encoding/base32"
	"strings"
	"testing"
)

func TestRecordCIDCanonicalFixture(t *testing.T) {
	// Independently encoded DAG-CBOR: {"a":1,"b":[true,null]}.
	digest := sha256.Sum256([]byte{0xa2, 0x61, 'a', 1, 0x61, 'b', 0x82, 0xf5, 0xf6})
	bytes := append([]byte{1, 0x71, 0x12, 0x20}, digest[:]...)
	expected := "b" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(bytes))
	for _, input := range []string{`{"b":[true,null],"a":1}`, `{"a":1e0,"b":[true,null]}`} {
		actual, err := RecordCID([]byte(input))
		if err != nil || actual != expected {
			t.Fatalf("%s: %s %v", input, actual, err)
		}
		if err := VerifyRecordCID([]byte(input), expected); err != nil {
			t.Fatal(err)
		}
	}
	if VerifyRecordCID([]byte(`{"a":2,"b":[true,null]}`), expected) == nil {
		t.Fatal("accepted changed record")
	}
	if VerifyRecordCID([]byte(`{"a":1,"b":[true,null]}`), strings.ToUpper(expected)) == nil {
		t.Fatal("accepted noncanonical CID")
	}
}

func TestRecordCIDRetainsExtensionsAndRejectsUnsafeValues(t *testing.T) {
	plain, _ := RecordCID([]byte(`{"a":1}`))
	extended, err := RecordCID([]byte(`{"a":1,"extension":{"$bytes":"AQI="}}`))
	if err != nil || plain == extended {
		t.Fatal("extension lost", err)
	}
	if _, err := RecordCID([]byte(`{"reference":{"$link":"` + plain + `"}}`)); err != nil {
		t.Fatal(err)
	}
	for _, input := range []string{`[]`, `{} {}`, `{"a":1.25}`, `{"a":9007199254740992}`, `{"a":{"$link":"invalid"}}`, `{"a":{"$bytes":"%%%"}}`} {
		if _, err := RecordCID([]byte(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}
