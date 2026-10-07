package podcastcore

type ManualLink struct {
	RSSShowID      string `json:"rssShowId"`
	ProtocolShowID string `json:"protocolShowId"`
}

func (v *ManualLink) UnmarshalJSON(data []byte) error {
	type plain ManualLink
	var decoded plain
	if err := decodeRequired(data, &decoded, "rssShowId", "protocolShowId"); err != nil {
		return err
	}
	*v = ManualLink(decoded)
	return nil
}
