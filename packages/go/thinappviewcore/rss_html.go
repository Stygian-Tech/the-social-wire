package thinappviewcore

import (
	"regexp"
	"strings"
)

var rssNoise = []*regexp.Regexp{regexp.MustCompile(`<script\b[^>]*>[\s\S]*?</script>`), regexp.MustCompile(`<style\b[^>]*>[\s\S]*?</style>`), regexp.MustCompile(`\bwindow\.[A-Za-z_$][\w$]*\s*=\s*\{[\s\S]*?\};?`), regexp.MustCompile(`\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*\{[\s\S]*?\};?`)}
var rssHTMLPattern = regexp.MustCompile(`<[a-zA-Z][^>]*>`)
var rssParagraphPattern = regexp.MustCompile(`\n{2,}`)

func RSSHTMLBody(content, summary *string) string {
	text := ""
	if content != nil {
		text = strings.TrimSpace(*content)
	}
	if text == "" && summary != nil {
		text = strings.TrimSpace(*summary)
	}
	if text == "" {
		return "<p></p>"
	}
	for _, pattern := range rssNoise {
		text = pattern.ReplaceAllString(text, "")
	}
	text = strings.TrimSpace(text)
	if rssHTMLPattern.MatchString(text) {
		return text
	}
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	output := ""
	escape := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;")
	for _, paragraph := range rssParagraphPattern.Split(text, -1) {
		lines := []string{}
		for _, line := range strings.Split(strings.TrimSpace(paragraph), "\n") {
			if line = strings.TrimSpace(line); line != "" {
				lines = append(lines, escape.Replace(line))
			}
		}
		if len(lines) > 0 {
			output += "<p>" + strings.Join(lines, "<br />") + "</p>"
		}
	}
	if output == "" {
		return "<p></p>"
	}
	return output
}
