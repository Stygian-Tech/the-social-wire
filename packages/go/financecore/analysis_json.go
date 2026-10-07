package financecore

import "encoding/json"

// Swift omits an absent optional macro array but preserves a supplied empty array.
func (a ArticleAnalysis) MarshalJSON() ([]byte, error) {
	type plain ArticleAnalysis
	var macro *[]string
	if a.MacroTopics != nil {
		macro = &a.MacroTopics
	}
	return json.Marshal(struct {
		plain
		MacroTopics *[]string `json:"macroTopics,omitempty"`
	}{plain(a), macro})
}
