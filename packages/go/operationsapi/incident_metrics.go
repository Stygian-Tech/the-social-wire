package operationsapi

type IncidentMetrics struct {
	Open                 int       `json:"open"`
	Recovering           int       `json:"recovering"`
	VerificationRequired int       `json:"verificationRequired"`
	Resolved             int       `json:"resolved"`
	Ignored              int       `json:"ignored"`
	LatestDetectedAt     *WireTime `json:"latestDetectedAt,omitempty"`
}
