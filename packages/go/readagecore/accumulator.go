package readagecore

import (
	"sort"
	"time"
)

type Accumulator struct {
	location *time.Location
	today    time.Time
	counts   map[int]int
}

func NewAccumulator(identifier string, now time.Time) (*Accumulator, error) {
	location, err := Location(identifier)
	if err != nil {
		return nil, err
	}
	local := now.In(location)
	today := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, location)
	return &Accumulator{location, today, map[int]int{}}, nil
}
func (a *Accumulator) Append(dates []time.Time) {
	todayCivil := time.Date(a.today.Year(), a.today.Month(), a.today.Day(), 0, 0, 0, 0, time.UTC)
	for _, at := range dates {
		if !at.Before(a.today) {
			continue
		}
		local := at.In(a.location)
		civil := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
		days := int(todayCivil.Sub(civil) / (24 * time.Hour))
		if days >= 1 {
			a.counts[min(days, 7)]++
		}
	}
}
func (a *Accumulator) Response() OptionsResponse {
	days := []int{}
	for day := range a.counts {
		days = append(days, day)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(days)))
	options := make([]Option, 0, len(days))
	count := 0
	for _, day := range days {
		count += a.counts[day]
		options = append(options, Option{Days: day, Before: Timestamp(a.today.AddDate(0, 0, -(day - 1))), Count: count})
	}
	for left, right := 0, len(options)-1; left < right; left, right = left+1, right-1 {
		options[left], options[right] = options[right], options[left]
	}
	return OptionsResponse{Options: options, ReferenceDay: Timestamp(a.today)}
}
