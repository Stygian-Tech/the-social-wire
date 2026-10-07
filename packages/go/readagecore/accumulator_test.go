package readagecore

import (
	"testing"
	"time"
)

func TestCivilDayAgesSurviveDSTAndUsePublisherDate(t *testing.T) {
	location, _ := time.LoadLocation("America/New_York")
	now := time.Date(2026, 3, 9, 12, 0, 0, 0, location)
	accumulator, err := NewAccumulator("America/New_York", now)
	if err != nil {
		t.Fatal(err)
	}
	accumulator.Append([]time.Time{time.Date(2026, 3, 8, 0, 30, 0, 0, location), time.Date(2026, 3, 2, 23, 59, 0, 0, location), now, now.Add(time.Hour)})
	response := accumulator.Response()
	if len(response.Options) != 2 || response.Options[0].Days != 1 || response.Options[0].Count != 2 || response.Options[1].Days != 7 || response.Options[1].Count != 1 || response.Options[0].Before != "2026-03-09T04:00:00.000Z" || response.Options[1].Before != "2026-03-03T05:00:00.000Z" {
		t.Fatalf("DST calendar ages: %#v", response)
	}
	if _, err := NewAccumulator("+03:00", now); err == nil {
		t.Fatal("numeric zone accepted")
	}
	if _, err := Cutoff(now.Add(time.Second).Format(time.RFC3339), now); err == nil {
		t.Fatal("future cutoff accepted")
	}
}
