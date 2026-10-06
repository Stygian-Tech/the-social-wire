package lexicons

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestGeneratedLexiconsMatchCanonicalSources(t *testing.T) {
	docs, err := Documents()
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	err = filepath.WalkDir("../../lexicons", func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".json") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var source Document
		if json.Unmarshal(data, &source) != nil || source.Lexicon != 1 || source.ID == "" {
			return nil
		}
		generated, ok := docs[source.ID]
		if !ok {
			t.Errorf("missing %s", source.ID)
			return nil
		}
		sourceJSON, _ := json.Marshal(source)
		generatedJSON, _ := json.Marshal(generated)
		var left, right any
		_ = json.Unmarshal(sourceJSON, &left)
		_ = json.Unmarshal(generatedJSON, &right)
		if !reflect.DeepEqual(left, right) {
			t.Errorf("schema drift for %s", source.ID)
		}
		count++
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if count != len(docs) {
		t.Fatalf("canonical count %d != generated %d", count, len(docs))
	}
}
func TestLexiconDefinitionsAreIsolated(t *testing.T) {
	schema, err := Resolve("#main", "app.thesocialwire.folder")
	if err != nil {
		t.Fatal(err)
	}
	schema[0] = '!'
	next, err := Resolve("app.thesocialwire.folder", "")
	if err != nil || next[0] == '!' {
		t.Fatal("schema mutation escaped caller", err)
	}
	if _, err := Resolve("#missing", "app.thesocialwire.folder"); err == nil {
		t.Fatal("unknown definition accepted")
	}
}
