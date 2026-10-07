package topicreadcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"testing"
	"time"
)

func TestCircleCachedPayloadRequiresCompleteEdition(t *testing.T) {
	value := CircleEdition{EditionVersion: "circle-edition-v1", GenerationID: "generation", GeneratedAt: time.Now().UTC(), Language: "en", Source: "circle", Stories: []CircleStory{}, TopStoryIDs: []string{}, PublicationSpotlights: []CircleSpotlight{}, StoryRails: []StoryRail{}, TrendingStoryIDs: []string{}}
	data, _ := corpuscore.MarshalHTTP(value)
	var restored CircleEdition
	if err := corpuscore.DecodeContract(data, &restored); err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	json.Unmarshal(data, &raw)
	for _, key := range []string{"stories", "degraded", "generatedAt", "publicationSpotlights"} {
		copy := map[string]any{}
		for k, v := range raw {
			copy[k] = v
		}
		delete(copy, key)
		bad, _ := json.Marshal(copy)
		if corpuscore.DecodeContract(bad, &restored) == nil {
			t.Fatal("incomplete cache accepted", key)
		}
	}
	if corpuscore.DecodeContract([]byte(`{}`), &restored) == nil {
		t.Fatal("empty edition accepted")
	}
}
