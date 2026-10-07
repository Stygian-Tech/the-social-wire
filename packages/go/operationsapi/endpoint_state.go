package operationsapi

type EndpointState struct {
	ID                 string    `json:"id"`
	Environment        string    `json:"environment"`
	DisplayName        string    `json:"displayName"`
	Host               string    `json:"host"`
	Role               string    `json:"role"`
	ConnectionState    string    `json:"connectionState"`
	LastConnectedAt    *WireTime `json:"lastConnectedAt,omitempty"`
	LastDisconnectedAt *WireTime `json:"lastDisconnectedAt,omitempty"`
	LastError          *string   `json:"lastError,omitempty"`
	ConnectionAttempts int       `json:"connectionAttempts"`
	FailoverCount      int       `json:"failoverCount"`
	UpdatedAt          WireTime  `json:"updatedAt"`
	Version            int       `json:"version"`
}
