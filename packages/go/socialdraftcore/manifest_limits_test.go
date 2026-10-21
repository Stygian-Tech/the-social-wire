package socialdraftcore

import (
	"fmt"
	"testing"
)

func TestManifestSupportsEveryPhotoInMaximumNativeThread(t *testing.T) {
	refs := make([]ManifestRef, 100*4*2)
	for i := range refs {
		refs[i] = ManifestRef{AssetID: "12345678-1234-1234-1234-123456789abc", Role: "original", Ref: fmt.Sprintf("post-photo-%d", i)}
	}
	if !validRefs(refs) {
		t.Fatal("100 posts with four original/prepared photos must fit")
	}
	refs = append(refs, ManifestRef{AssetID: refs[0].AssetID, Role: "prepared", Ref: "one-too-many"})
	if validRefs(refs) {
		t.Fatal("oversized manifests must remain bounded")
	}
}
