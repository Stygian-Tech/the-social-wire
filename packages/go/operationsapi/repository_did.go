package operationsapi

import (
	"net"
	"strconv"
	"strings"
)

// Recovery accepts only public repository identities, never synthetic or local hosts.
func ValidRecoveryRepositoryDID(did string) bool {
	if strings.TrimSpace(did) != did {
		return false
	}
	if strings.HasPrefix(did, "did:plc:") {
		s := strings.TrimPrefix(did, "did:plc:")
		if len(s) != 24 {
			return false
		}
		for _, c := range s {
			if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
				return false
			}
		}
		return true
	}
	if !strings.HasPrefix(did, "did:web:") || strings.EqualFold(did, "did:web:skyreader.rss") {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(did, "did:web:"), ":")
	host := strings.ToLower(parts[0])
	if len(host) > 253 || !strings.Contains(host, ".") || (net.ParseIP(host) != nil || recoveryIPv4Literal(host)) {
		return false
	}
	for _, b := range []string{"example.com", "example.net", "example.org"} {
		if host == b {
			return false
		}
	}
	for _, b := range []string{".localhost", ".local", ".internal", ".home", ".lan", ".test", ".invalid", ".example", ".onion", ".arpa"} {
		if strings.HasSuffix(host, b) {
			return false
		}
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	for _, segment := range parts[1:] {
		if segment == "" {
			return false
		}
		for i := 0; i < len(segment); i++ {
			c := segment[i]
			if c == '%' {
				if i+2 >= len(segment) || !isHexByte(segment[i+1]) || !isHexByte(segment[i+2]) {
					return false
				}
				i += 2
				continue
			}
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-._~", rune(c))) {
				return false
			}
		}
	}
	return true
}
func isHexByte(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

func recoveryIPv4Literal(host string) bool {
	parts := strings.Split(host, ".")
	if len(parts) != 4 {
		return false
	}
	for _, part := range parts {
		if len(part) == 0 || len(part) > 3 {
			return false
		}
		for _, c := range part {
			if c < '0' || c > '9' {
				return false
			}
		}
		value, err := strconv.Atoi(part)
		if err != nil || value > 255 {
			return false
		}
	}
	return true
}
