package operationsapi

type DatabaseTableRecordCount struct {
	Schema           string `json:"schema"`
	Table            string `json:"table"`
	EstimatedRecords int64  `json:"estimatedRecords"`
}
