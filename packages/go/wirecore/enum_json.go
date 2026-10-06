package wirecore

import (
	"encoding/json"
	"fmt"
)

func (k *TargetKind) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch TargetKind(value) {
	case ExternalArticle, StandardSiteDocument, SocialPost, ProfileOrFeed, CommerceOrAd, OperationalStatus, Unsupported:
		*k = TargetKind(value)
		return nil
	default:
		return fmt.Errorf("invalid Wire target kind %q", value)
	}
}
func (k *CommercialClass) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch CommercialClass(value) {
	case Normal, Limited, ProbableAd:
		*k = CommercialClass(value)
		return nil
	default:
		return fmt.Errorf("invalid Wire commercial class %q", value)
	}
}
func (k *ReasonCode) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch ReasonCode(value) {
	case BreakingStory, FreshPublication, Resurfacing, SharedAcrossCommunities, WidelyDiscussed:
		*k = ReasonCode(value)
		return nil
	default:
		return fmt.Errorf("invalid Wire reason code %q", value)
	}
}
