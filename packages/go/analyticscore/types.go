package analyticscore

import "time"

type Engagement struct {
	Likes   int `json:"likes"`
	Replies int `json:"replies"`
	Reposts int `json:"reposts"`
	Quotes  int `json:"quotes"`
}
type Tracking struct {
	Impressions    int      `json:"impressions"`
	Views          int      `json:"views"`
	OutboundClicks int      `json:"outboundClicks"`
	CTR            *float64 `json:"ctr"`
}
type Item struct {
	URI         string      `json:"uri"`
	Kind        string      `json:"kind"`
	Title       string      `json:"title"`
	URL         string      `json:"url"`
	PublishedAt string      `json:"publishedAt"`
	Engagement  *Engagement `json:"engagement"`
	Tracking    Tracking    `json:"tracking"`
	RefreshedAt time.Time   `json:"refreshedAt"`
}
type Day struct {
	Day            string   `json:"day"`
	Likes          *int     `json:"likes"`
	Replies        *int     `json:"replies"`
	Reposts        *int     `json:"reposts"`
	Quotes         *int     `json:"quotes"`
	Impressions    *int     `json:"impressions"`
	Views          *int     `json:"views"`
	OutboundClicks *int     `json:"outboundClicks"`
	CTR            *float64 `json:"ctr"`
}
type Coverage struct {
	TrackingStart         *string    `json:"trackingStart"`
	SampledAt             *time.Time `json:"sampledAt"`
	EngagementKnownItems  int        `json:"engagementKnownItems"`
	TotalItems            int        `json:"totalItems"`
	ExcludesSelf          bool       `json:"excludesSelf"`
	TrackingRetentionDays int        `json:"trackingRetentionDays"`
	SnapshotStart         *string    `json:"snapshotStart"`
	InventoryComplete     bool       `json:"inventoryComplete"`
	TrackingScope         string     `json:"trackingScope"`
	PlatformImpressions   *int       `json:"platformImpressions"`
	SnapshotSemantics     string     `json:"snapshotSemantics"`
}
type Summary struct {
	Items  []Item `json:"items"`
	Totals struct {
		Engagement *Engagement `json:"engagement"`
		Tracking   Tracking    `json:"tracking"`
	} `json:"totals"`
	Series   []Day    `json:"series"`
	Coverage Coverage `json:"coverage"`
	Cursor   string   `json:"cursor,omitempty"`
}
type Event struct {
	SubjectURI string `json:"subjectUri"`
	Event      string `json:"event"`
	Surface    string `json:"surface"`
}

func (t *Tracking) CalculateCTR() {
	if t.Impressions > 0 {
		v := 100 * float64(t.OutboundClicks) / float64(t.Impressions)
		if v > 100 {
			v = 100
		}
		t.CTR = &v
	}
}
