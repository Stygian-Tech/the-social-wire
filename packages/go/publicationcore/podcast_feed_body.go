package publicationcore

import (
	"bytes"
	"encoding/xml"
	"io"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

// Podcast feeds are RSS/Atom too, but must not become News subscriptions. Check
// podcast metadata as well as audio enclosures so empty shows remain isolated.
func podcastFeedBody(body []byte) bool {
	decoder := xml.NewDecoder(bytes.NewReader(body))
	podcast := false
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return podcast
		}
		if err != nil {
			return podcast
		}
		element, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		namespace := strings.ToLower(element.Name.Space)
		if namespace == "http://www.itunes.com/dtds/podcast-1.0.dtd" || namespace == "https://www.itunes.com/dtds/podcast-1.0.dtd" || namespace == "https://podcastindex.org/namespace/1.0" {
			podcast = true
		}
		if element.Name.Local != "enclosure" && element.Name.Local != "link" {
			continue
		}
		attributes := map[string]string{}
		for _, attribute := range element.Attr {
			attributes[attribute.Name.Local] = attribute.Value
		}
		if element.Name.Local == "link" && attributes["rel"] != "enclosure" {
			continue
		}
		target := attributes["url"]
		if target == "" {
			target = attributes["href"]
		}
		var mime *string
		if value := attributes["type"]; value != "" {
			mime = &value
		}
		if target != "" && podcastcore.IsAudio(target, mime) {
			podcast = true
		}
	}
}
