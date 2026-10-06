package spec

import "github.com/pb33f/libopenapi"

// OpenAPIDocument exposes the library's document directly. Canonical source
// remains repository-local; callers use libopenapi for models and references.
func OpenAPIDocument() (libopenapi.Document, error) {
	return libopenapi.NewDocument([]byte(OpenAPI))
}
