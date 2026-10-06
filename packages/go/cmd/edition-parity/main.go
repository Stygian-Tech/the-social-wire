package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func main() {
	var request struct {
		Items    []wirecore.FeedItem                    `json:"items"`
		Accounts []wirecore.TalkedAboutAccountCandidate `json:"accounts"`
		AsOf     time.Time                              `json:"asOf"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(wirecore.AssembleEdition("fixture", request.AsOf, "und", nil, "ranked", false, request.Items, request.Accounts)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
