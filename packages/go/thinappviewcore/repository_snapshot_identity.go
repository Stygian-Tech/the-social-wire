package thinappviewcore

import (
	"context"
	"encoding/json"
	"github.com/jcalabro/atmos/crypto"
)

// Resolve afresh: the signing key and endpoint must belong to the same exact
// DID document, not a cached PDS endpoint from before an account migration.
func (s *snapshotRead) identity(ctx context.Context, did string) (string, crypto.PublicKey, error) {
	root := s.reader.PDS.PLCBase
	if root == "" {
		root = "https://plc.directory"
	}
	target, err := didDocumentURL(did, root)
	if err != nil {
		return "", nil, snapshotError("invalid identity")
	}
	body, err := s.get(ctx, target, "application/json", 65536)
	if err != nil {
		return "", nil, err
	}
	var document struct {
		ID      string `json:"id"`
		Service []struct {
			ID, Type string
			Endpoint string `json:"serviceEndpoint"`
		} `json:"service"`
		Keys []struct {
			ID, Controller, Type string
			Multibase            string `json:"publicKeyMultibase"`
		} `json:"verificationMethod"`
	}
	if json.Unmarshal(body, &document) != nil || document.ID != did {
		return "", nil, snapshotError("identity mismatch")
	}
	base := ""
	services := 0
	for _, service := range document.Service {
		if service.Type == "AtprotoPersonalDataServer" {
			services++
		}
		if (service.ID == "#atproto_pds" || service.ID == did+"#atproto_pds") && service.Type == "AtprotoPersonalDataServer" {
			base = ValidatePDSBase(service.Endpoint)
		}
	}
	if services != 1 || base == "" {
		return "", nil, snapshotError("invalid PDS binding")
	}
	var key crypto.PublicKey
	keys := 0
	for _, method := range document.Keys {
		if method.ID == "#atproto" || method.ID == did+"#atproto" {
			keys++
			if method.Controller != did || method.Type != "Multikey" {
				return "", nil, snapshotError("invalid signing key binding")
			}
			key, err = crypto.ParsePublicMultibase(method.Multibase)
			if err != nil {
				return "", nil, snapshotError("invalid signing key")
			}
		}
	}
	if keys != 1 || key == nil {
		return "", nil, snapshotError("missing signing key")
	}
	return base, key, nil
}
