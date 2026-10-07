package wireworkercore

import (
	"encoding/json"
	"html"
	"io"
	"net/url"
	"strings"
	"time"

	htmlparse "golang.org/x/net/html"
)

func metadataText(raw string) *string {
	text := strings.Join(strings.Fields(html.UnescapeString(raw)), " ")
	if text == "" {
		return nil
	}
	runes := []rune(text)
	if len(runes) > 2000 {
		text = string(runes[:2000])
	}
	return &text
}
func metadataFirst(values ...string) *string {
	for _, value := range values {
		if text := metadataText(value); text != nil {
			return text
		}
	}
	return nil
}
func metadataURL(raw string, base *url.URL) *string {
	text := metadataText(raw)
	if text == nil {
		return nil
	}
	ref, err := url.Parse(*text)
	if err != nil {
		return nil
	}
	result := base.ResolveReference(ref)
	if result.Hostname() == "" || (result.Scheme != "http" && result.Scheme != "https") {
		return nil
	}
	return stringPointer(result.String())
}
func jsonLDText(value any) string { text, _ := value.(string); return text }
func jsonLDName(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case map[string]any:
		return jsonLDText(v["name"])
	case []any:
		for _, item := range v {
			if result := jsonLDName(item); result != "" {
				return result
			}
		}
	}
	return ""
}
func jsonLDURL(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case map[string]any:
		if result := jsonLDText(v["url"]); result != "" {
			return result
		}
		return jsonLDText(v["@id"])
	case []any:
		for _, item := range v {
			if result := jsonLDURL(item); result != "" {
				return result
			}
		}
	}
	return ""
}
func jsonLDLanguage(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case map[string]any:
		if result := jsonLDText(v["name"]); result != "" {
			return result
		}
		return jsonLDText(v["@id"])
	case []any:
		for _, item := range v {
			if result := jsonLDLanguage(item); result != "" {
				return result
			}
		}
	}
	return ""
}
func jsonLDObjects(value any, depth int, result *[]map[string]any) {
	if depth > 32 || len(*result) >= 100 {
		return
	}
	switch v := value.(type) {
	case map[string]any:
		*result = append(*result, v)
		jsonLDObjects(v["@graph"], depth+1, result)
	case []any:
		for _, child := range v {
			jsonLDObjects(child, depth+1, result)
			if len(*result) >= 100 {
				return
			}
		}
	}
}
func jsonLDTypes(value any) []string {
	switch v := value.(type) {
	case string:
		return []string{strings.ToLower(v)}
	case []any:
		var result []string
		for _, child := range v {
			if text, ok := child.(string); ok {
				result = append(result, strings.ToLower(text))
			}
		}
		return result
	}
	return nil
}
func parseMetadataHTML(body []byte, rawURL string) (*LinkMetadata, error) {
	base, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	properties := map[string]string{}
	var title, htmlLang, icon, canonical string
	var jsonBlocks []string
	tokenizer := htmlparse.NewTokenizer(strings.NewReader(string(body)))
	for {
		kind := tokenizer.Next()
		if kind == htmlparse.ErrorToken {
			if tokenizer.Err() != io.EOF {
				return nil, tokenizer.Err()
			}
			break
		}
		if kind != htmlparse.StartTagToken && kind != htmlparse.SelfClosingTagToken {
			continue
		}
		token := tokenizer.Token()
		attrs := map[string]string{}
		for _, attr := range token.Attr {
			key := strings.ToLower(attr.Key)
			if _, exists := attrs[key]; !exists {
				attrs[key] = attr.Val
			}
		}
		switch token.Data {
		case "meta":
			key := strings.ToLower(attrs["property"])
			if key == "" {
				key = strings.ToLower(attrs["name"])
			}
			if key != "" && properties[key] == "" {
				properties[key] = attrs["content"]
			}
		case "link":
			for _, rel := range strings.Fields(strings.ToLower(attrs["rel"])) {
				if rel == "canonical" && canonical == "" {
					canonical = attrs["href"]
				}
				if (rel == "icon" || rel == "shortcut" || rel == "apple-touch-icon") && icon == "" {
					icon = attrs["href"]
				}
			}
		case "html":
			if htmlLang == "" {
				htmlLang = attrs["lang"]
			}
		case "title":
			if title == "" && tokenizer.Next() == htmlparse.TextToken {
				title = string(tokenizer.Text())
			}
		case "script":
			if strings.EqualFold(attrs["type"], "application/ld+json") && len(jsonBlocks) < 20 && tokenizer.Next() == htmlparse.TextToken {
				block := string(tokenizer.Text())
				if len(block) <= 256000 {
					jsonBlocks = append(jsonBlocks, block)
				}
			}
		}
	}
	var article map[string]any
	product, affiliate := false, false
	for _, block := range jsonBlocks {
		var root any
		if json.Unmarshal([]byte(block), &root) != nil {
			continue
		}
		var objects []map[string]any
		jsonLDObjects(root, 0, &objects)
		for _, object := range objects {
			for _, kind := range jsonLDTypes(object["@type"]) {
				if kind == "product" || kind == "offer" {
					product = true
				}
				if article == nil && (kind == "article" || kind == "newsarticle" || kind == "blogposting" || kind == "reportagenewsarticle") {
					article = object
				}
			}
			if object["offers"] != nil {
				product = true
			}
			for _, key := range []string{"keywords", "tags"} {
				values := jsonLDTypes(object[key])
				for _, value := range values {
					for _, word := range strings.FieldsFunc(value, func(c rune) bool { return c < 'a' || c > 'z' }) {
						if word == "affiliate" {
							affiliate = true
						}
					}
				}
			}
		}
	}
	for _, marker := range []string{"we may receive a portion of sales", "we may earn a commission", "may earn an affiliate commission", "may receive compensation through affiliate"} {
		if strings.Contains(strings.ToLower(string(body)), marker) {
			affiliate = true
		}
	}
	publisher, _ := article["publisher"].(map[string]any)
	partOf, _ := article["isPartOf"].(map[string]any)
	m := &LinkMetadata{URL: rawURL, Title: metadataFirst(properties["og:title"], properties["twitter:title"], jsonLDText(article["headline"]), jsonLDText(article["name"]), title), Description: metadataFirst(properties["og:description"], properties["twitter:description"], properties["description"], jsonLDText(article["description"])), SiteName: metadataFirst(properties["og:site_name"], properties["application-name"], jsonLDText(publisher["name"]), jsonLDText(partOf["name"])), AuthorName: metadataFirst(properties["article:author"], properties["author"], properties["byl"], properties["twitter:creator"], jsonLDName(article["author"])), ProductOffer: product, Affiliate: affiliate}
	m.ImageURL = metadataURL(optionalText(metadataFirst(properties["og:image:secure_url"], properties["og:image"], properties["twitter:image"], jsonLDURL(article["image"]))), base)
	m.IconURL = metadataURL(optionalText(metadataFirst(icon, jsonLDURL(publisher["logo"]))), base)
	if target := metadataURL(optionalText(metadataFirst(canonical, jsonLDURL(article["mainEntityOfPage"]), jsonLDText(article["url"]))), base); target != nil {
		m.URL = *target
	}
	for _, date := range []string{properties["article:published_time"], properties["og:published_time"], properties["date"], properties["datepublished"], jsonLDText(article["datePublished"])} {
		if parsed, err := time.Parse(time.RFC3339Nano, date); err == nil {
			m.PublishedAt = &parsed
			break
		}
	}
	for _, language := range []string{jsonLDLanguage(article["inLanguage"]), properties["og:locale"], htmlLang} {
		if named, ok := languageNames[strings.ToLower(strings.TrimSpace(language))]; ok {
			language = named
		}
		if code := normalizePageLanguage(language); code != "" {
			m.Language = &code
			break
		}
	}
	if m.Title == nil && m.Description == nil && m.ImageURL == nil && m.SiteName == nil && m.AuthorName == nil && m.PublishedAt == nil && m.IconURL == nil {
		return nil, nil
	}
	return m, nil
}
