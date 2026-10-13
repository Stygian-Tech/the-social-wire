package sportscore

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

// PresentationFingerprint matches PostgreSQL octet_length/UTF8 framing without
// depending on JSON whitespace. Null and empty summaries remain distinct.
func PresentationFingerprint(item wirecore.FeedItem) string {
	var framed strings.Builder
	write := func(value string) {
		framed.WriteString(strconv.Itoa(len(value)))
		framed.WriteByte(':')
		framed.WriteString(value)
	}
	write(item.Title)
	if item.Summary == nil {
		framed.WriteByte('N')
	} else {
		framed.WriteByte('S')
		write(*item.Summary)
	}
	write(item.Source.Domain)
	digest := sha256.Sum256([]byte(framed.String()))
	return hex.EncodeToString(digest[:])
}

// PresentationMatches supports legacy full snapshots and lean source snapshots.
// A changed digest forces reanalysis of the currently eligible hydrated item.
func (candidate RankCandidate) PresentationMatches(item wirecore.FeedItem) bool {
	if candidate.PresentationFingerprint != "" {
		return candidate.PresentationFingerprint == PresentationFingerprint(item)
	}
	summariesEqual := candidate.Item.Summary == nil && item.Summary == nil || candidate.Item.Summary != nil && item.Summary != nil && *candidate.Item.Summary == *item.Summary
	return candidate.Item.Title == item.Title && candidate.Item.Source.Domain == item.Source.Domain && summariesEqual
}
