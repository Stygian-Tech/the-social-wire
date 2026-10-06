// ranking-parity runs pure Wire ranking on an explicit input snapshot. It does
// not connect to PostgreSQL, acquire authority, or publish generations.
package main

import (
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"os"
	"time"
)

func main() {
	var input struct {
		Candidates []wirecore.Candidate    `json:"candidates"`
		AsOf       time.Time               `json:"asOf"`
		Config     *wirecore.RankingConfig `json:"config"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	config := wirecore.DefaultRankingConfig()
	if input.Config != nil {
		config = *input.Config
	}
	result, err := wirecore.Rank(input.Candidates, input.AsOf, config)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
