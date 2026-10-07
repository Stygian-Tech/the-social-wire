package semblecore

type Error struct {
	Status    int    `json:"-"`
	Code      string `json:"error"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

func (e *Error) Error() string       { return e.Message }
func Invalid(message string) *Error  { return &Error{400, "invalid_request", message, false} }
func upstream(message string) *Error { return &Error{502, "semble_projection_failed", message, true} }

var Forbidden = &Error{403, "collection_owner_mismatch", "The configured Semble collection must be owned by the authenticated viewer.", false}
var NotFound = &Error{404, "semble_collection_not_found", "The configured Semble collection was not found.", false}
