package operationsapi

type MetricRollup struct {
	Environment string            `json:"environment"`
	BucketStart WireTime          `json:"bucketStart"`
	MetricName  string            `json:"metricName"`
	Dimensions  map[string]string `json:"dimensions"`
	SampleCount int               `json:"sampleCount"`
	ValueSum    float64           `json:"valueSum"`
	ValueMin    *float64          `json:"valueMin,omitempty"`
	ValueMax    *float64          `json:"valueMax,omitempty"`
}
