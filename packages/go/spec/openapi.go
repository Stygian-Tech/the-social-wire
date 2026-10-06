package spec

// Returns libopenapi documents directly so callers use the upstream OpenAPI 3.1
// model/reference implementation. Building a model is separate from creating the document
// and from checking service route conformance.

import "github.com/pb33f/libopenapi"

// OpenAPIDocument exposes the library's document directly. Canonical source
// remains repository-local; callers use libopenapi for models and references.
func OpenAPIDocument() (libopenapi.Document, error) {
	return libopenapi.NewDocument([]byte(OpenAPI))
}
