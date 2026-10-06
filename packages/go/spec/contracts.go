// Package spec exposes contracts generated from canonical repository API sources.
package spec

import (
	"encoding/json"
	"strings"
)

type Endpoint struct {
	Surface        string `json:"surface"`
	Method         string `json:"method"`
	Path           string `json:"path"`
	Classification string `json:"classification"`
	XRPCNSID       string `json:"xrpcNsid,omitempty"`
}

func Endpoints() ([]Endpoint, error) {
	var manifest struct {
		Version int        `json:"version"`
		Entries []Endpoint `json:"entries"`
	}
	if err := json.Unmarshal([]byte(endpointManifest), &manifest); err != nil {
		return nil, err
	}
	return manifest.Entries, nil
}
func Find(surface, method, path string) (Endpoint, bool) {
	entries, err := Endpoints()
	if err != nil {
		return Endpoint{}, false
	}
	for _, e := range entries {
		if e.Surface == surface && e.Method == strings.ToUpper(method) && e.Path == path {
			return e, true
		}
	}
	return Endpoint{}, false
}
