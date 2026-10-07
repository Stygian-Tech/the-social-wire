package publicationcore

import (
	"encoding/json"
	"reflect"
	"strings"
	"time"
)

type FolderPayload struct {
	FolderSections     []FolderSection `json:"folderSections"`
	AllPublicationRows []SidebarRow    `json:"allPublicationRows"`
}
type BootstrapSnapshot struct {
	Version       int            `json:"version"`
	Priority      Sidebar        `json:"priority"`
	FolderPayload *FolderPayload `json:"folderPayload,omitempty"`
}

func (s BootstrapSnapshot) Sidebar() Sidebar {
	result := s.Priority
	if s.FolderPayload != nil {
		result.FolderSections = s.FolderPayload.FolderSections
		byID := map[string]SidebarRow{}
		for _, row := range append(append([]SidebarRow{}, result.AllPublicationRows...), s.FolderPayload.AllPublicationRows...) {
			byID[row.PublicationID] = row
		}
		result.AllPublicationRows = []SidebarRow{}
		for _, row := range byID {
			result.AllPublicationRows = append(result.AllPublicationRows, row)
		}
	}
	return result
}

// Swift's internal sidebar snapshots use Foundation's default reference date,
// whereas the public NDJSON contract uses ISO8601. Preserve both independently.
func snapshotJSON(snapshot BootstrapSnapshot) (string, error) {
	raw, e := json.Marshal(snapshot)
	if e != nil {
		return "", e
	}
	var value any
	if e = json.Unmarshal(raw, &value); e != nil {
		return "", e
	}
	value = referenceDates(value, reflect.ValueOf(snapshot))
	raw, e = json.Marshal(value)
	return string(raw), e
}
func decodeSnapshot(raw string) (BootstrapSnapshot, error) {
	var value any
	e := json.Unmarshal([]byte(raw), &value)
	if e != nil {
		return BootstrapSnapshot{}, e
	}
	transformDates(value, false)
	data, e := json.Marshal(value)
	if e != nil {
		return BootstrapSnapshot{}, e
	}
	var result BootstrapSnapshot
	e = json.Unmarshal(data, &result)
	return result, e
}
func transformDates(value any, encode bool) {
	switch v := value.(type) {
	case map[string]any:
		for key, item := range v {
			if key == "refreshedAt" || key == "discoveredAt" {
				if encode {
					if s, ok := item.(string); ok {
						if at, e := time.Parse(time.RFC3339Nano, s); e == nil {
							v[key] = float64(at.UnixNano())/1e9 - 978307200
						}
					}
				} else {
					if seconds, ok := item.(float64); ok {
						v[key] = time.Unix(0, int64((seconds+978307200)*1e9)).UTC().Format(time.RFC3339Nano)
					}
				}
			}
			transformDates(item, encode)
		}
	case []any:
		for _, item := range v {
			transformDates(item, encode)
		}
	}
}

func referenceDates(value any, source reflect.Value) any {
	if !source.IsValid() {
		return value
	}
	if source.Kind() == reflect.Pointer {
		if source.IsNil() {
			return value
		}
		return referenceDates(value, source.Elem())
	}
	if source.Type() == reflect.TypeOf(time.Time{}) {
		at := source.Interface().(time.Time)
		return float64(at.UnixNano())/1e9 - 978307200
	}
	switch source.Kind() {
	case reflect.Struct:
		if object, ok := value.(map[string]any); ok {
			for i := 0; i < source.NumField(); i++ {
				field := source.Type().Field(i)
				key := strings.Split(field.Tag.Get("json"), ",")[0]
				if key == "" {
					key = field.Name
				}
				if item, exists := object[key]; exists {
					object[key] = referenceDates(item, source.Field(i))
				}
			}
		}
	case reflect.Slice:
		if array, ok := value.([]any); ok {
			for i := 0; i < len(array) && i < source.Len(); i++ {
				array[i] = referenceDates(array[i], source.Index(i))
			}
		}
	}
	return value
}
