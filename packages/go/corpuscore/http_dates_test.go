package corpuscore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"testing"
	"time"
)

func TestHTTPMembershipDatesUseISOSeconds(t *testing.T) {
	at := time.Date(2026, 10, 7, 3, 2, 1, 765000000, time.UTC)
	end := at.Add(time.Hour)
	entity := sportscore.Entity{ID: "team", Name: "Team", Kind: "team", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true, Memberships: []sportscore.Membership{{EntityID: "competition", ValidFrom: at, ValidUntil: &end}}}
	data, err := MarshalHTTP(struct {
		Value any `json:"value"`
	}{entity})
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err = json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	object = object["value"].(map[string]any)
	membership := object["memberships"].([]any)[0].(map[string]any)
	if membership["validFrom"] != "2026-10-07T03:02:01Z" || membership["validUntil"] != "2026-10-07T04:02:01Z" {
		t.Fatal(string(data))
	}
	var restored sportscore.Entity
	if err = json.Unmarshal(func() []byte { b, _ := json.Marshal(object); return b }(), &restored); err != nil {
		t.Fatal(err)
	}
	if !restored.Memberships[0].ValidFrom.Equal(at.Truncate(time.Second)) {
		t.Fatal(restored)
	}
}
