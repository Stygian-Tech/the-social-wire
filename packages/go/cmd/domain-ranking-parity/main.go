package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func fail(err error) { fmt.Fprintln(os.Stderr, err); os.Exit(1) }
func main() {
	var request struct {
		Finance       []financecore.RankCandidate `json:"finance"`
		Sports        []sportscore.RankCandidate  `json:"sports"`
		InstrumentIDs []string                    `json:"instrumentIDs"`
		SectorIDs     []string                    `json:"sectorIDs"`
		FollowIDs     []string                    `json:"followIDs"`
		MuteIDs       []string                    `json:"muteIDs"`
		Entities      []sportscore.Entity         `json:"entities"`
		ReserveGlobal bool                        `json:"reserveGlobal"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil {
		fail(err)
	}
	set := func(ids []string) map[string]bool {
		m := map[string]bool{}
		for _, id := range ids {
			m[id] = true
		}
		return m
	}
	finance := financecore.Rank(request.Finance, set(request.InstrumentIDs), set(request.SectorIDs), request.ReserveGlobal)
	sports := sportscore.Rank(request.Sports, set(request.FollowIDs), set(request.MuteIDs), request.Entities, request.ReserveGlobal)
	result := struct {
		Finance []string `json:"finance"`
		Sports  []string `json:"sports"`
	}{[]string{}, []string{}}
	for _, c := range finance {
		result.Finance = append(result.Finance, c.Item.ItemID)
	}
	for _, c := range sports {
		result.Sports = append(result.Sports, c.Item.ItemID)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fail(err)
	}
}
