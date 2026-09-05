package store

import "strings"

func postgresApplicationName(serviceName string) string {
	serviceName = strings.TrimSpace(serviceName)
	if serviceName == "" {
		return "jetstream-ingest"
	}
	var name strings.Builder
	for _, character := range serviceName {
		if name.Len() == 63 {
			break
		}
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || strings.ContainsRune("-_.", character) {
			name.WriteRune(character)
		} else {
			name.WriteByte('-')
		}
	}
	return name.String()
}
