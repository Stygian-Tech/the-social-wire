package wirecore

// Rejects unrecognized JSON enum strings instead of silently accepting future target,
// commercial, or reason values. Database candidate loading separately maps unknown
// persisted values to conservative rejection classes.

import (
	"encoding/json"
	"fmt"
)

// UnmarshalJSON decodes the shared wire representation while enforcing this type’s
// compatibility rules.
func (targetKind *TargetKind) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch TargetKind(value) {
	case ExternalArticle, StandardSiteDocument, SocialPost, ProfileOrFeed, CommerceOrAd, OperationalStatus, Unsupported:
		*targetKind = TargetKind(value)
		return nil
	default:
		return fmt.Errorf("invalid Wire target kind %q", value)
	}
}

// UnmarshalJSON decodes the shared wire representation while enforcing this type’s
// compatibility rules.
func (commercialClass *CommercialClass) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch CommercialClass(value) {
	case Normal, Limited, ProbableAd:
		*commercialClass = CommercialClass(value)
		return nil
	default:
		return fmt.Errorf("invalid Wire commercial class %q", value)
	}
}

// UnmarshalJSON decodes the shared wire representation while enforcing this type’s
// compatibility rules.
func (reasonCode *ReasonCode) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch ReasonCode(value) {
	case BreakingStory, FreshPublication, Resurfacing, SharedAcrossCommunities, WidelyDiscussed:
		*reasonCode = ReasonCode(value)
		return nil
	default:
		return fmt.Errorf("invalid Wire reason code %q", value)
	}
}
