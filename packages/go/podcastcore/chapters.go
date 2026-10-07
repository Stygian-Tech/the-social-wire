package podcastcore

import (
	"encoding/json"
	"math"
	"sort"
	"strings"

	"github.com/rivo/uniseg"
)

func safeURL(s *string) *string {
	if s != nil && PrivateURLAllowed(*s) {
		return s
	}
	return nil
}
func prefix(s string, n int) string {
	g := uniseg.NewGraphemes(s)
	end := 0
	for i := 0; i < n && g.Next(); i++ {
		_, end = g.Positions()
	}
	return s[:end]
}
func rowString(row map[string]any, keys ...string) *string {
	for _, k := range keys {
		if v, ok := row[k]; ok {
			s, ok := v.(string)
			if ok {
				return &s
			}
			return nil
		}
	}
	return nil
}
func ParseChapters(data []byte, duration *float64) []Chapter {
	var value any
	if json.Unmarshal(data, &value) != nil {
		return []Chapter{}
	}
	if object, ok := value.(map[string]any); ok {
		value = object["chapters"]
	}
	rows, _ := value.([]any)
	return ChapterRows(rows, duration)
}
func ChapterRows(rows []any, duration *float64) []Chapter {
	result := []Chapter{}
	for i, v := range rows {
		if i >= 1000 {
			break
		}
		row, ok := v.(map[string]any)
		if !ok {
			continue
		}
		if toc, ok := row["toc"].(bool); ok && !toc {
			continue
		}
		var raw any
		for _, key := range []string{"startSeconds", "startTime", "start"} {
			if v, ok := row[key]; ok {
				raw = v
				break
			}
		}
		start, ok := raw.(float64)
		if !ok || math.IsNaN(start) || math.IsInf(start, 0) || start < 0 || duration != nil && !(start < *duration) {
			continue
		}
		title := "Chapter"
		if s := rowString(row, "title"); s != nil {
			title = *s
		}
		result = append(result, Chapter{StartSeconds: start, Title: prefix(title, 512), ArtworkURL: safeURL(rowString(row, "artworkUrl", "img", "image")), URL: safeURL(rowString(row, "url", "href"))})
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].StartSeconds < result[j].StartSeconds })
	return result
}
func PeopleRows(rows []any) []Person {
	result := []Person{}
	for i, v := range rows {
		if i >= 100 {
			break
		}
		row, ok := v.(map[string]any)
		if !ok {
			continue
		}
		name := rowString(row, "name")
		if name == nil || strings.TrimSpace(*name) == "" {
			continue
		}
		role := "host"
		if s := rowString(row, "role"); s != nil {
			role = *s
		}
		switch strings.ToLower(role) {
		case "host", "co-host", "cohost":
		default:
			continue
		}
		result = append(result, Person{Name: prefix(*name, 128), Role: pointer(role), ImageURL: safeURL(rowString(row, "imageUrl", "img", "image")), URL: safeURL(rowString(row, "url", "href"))})
	}
	return result
}
