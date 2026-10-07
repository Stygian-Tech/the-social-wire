// Package spec exposes contracts generated from canonical repository API sources.
package spec

// Reads the generated canonical endpoint manifest and looks up exact surface/path pairs
// with an uppercase method. An endpoint classification describes the contract, not runtime
// route availability.

import (
	"encoding/json"
	"strings"
)

// Endpoint describes a canonical route’s surface, method, path, classification, and
// optional XRPC NSID.
type Endpoint struct {
	Surface        string `json:"surface"`
	Method         string `json:"method"`
	Path           string `json:"path"`
	Classification string `json:"classification"`
	XRPCNSID       string `json:"xrpcNsid,omitempty"`
}

// Endpoints decodes an independent list from the embedded endpoint manifest.
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

// Find matches surface/path exactly and normalizes the requested method to uppercase.
func Find(surface, method, path string) (Endpoint, bool) {
	entries, err := Endpoints()
	if err != nil {
		return Endpoint{}, false
	}
	for _, endpoint := range entries {
		if endpoint.Surface == surface && endpoint.Method == strings.ToUpper(method) && endpoint.Path == path {
			return endpoint, true
		}
	}
	return Endpoint{}, false
}
