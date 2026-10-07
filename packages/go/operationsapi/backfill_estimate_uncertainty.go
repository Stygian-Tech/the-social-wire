package operationsapi

type BackfillEstimateUncertainty struct {
	LowerBound int `json:"lowerBound"`
	UpperBound int `json:"upperBound"`
}
