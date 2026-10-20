package socialdraftcore

import (
	"bufio"
	"io"
	"strings"
	"unicode/utf8"
)

// Captions must be UTF-8 WebVTT with bounded lines and no binary control bytes.
func validateCaption(r io.Reader) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	first := true
	for scanner.Scan() {
		b := scanner.Bytes()
		if !utf8.Valid(b) {
			return ErrInvalid
		}
		line := string(b)
		if first {
			line = strings.TrimPrefix(line, "\ufeff")
			if line != "WEBVTT" && !strings.HasPrefix(line, "WEBVTT ") && !strings.HasPrefix(line, "WEBVTT\t") {
				return ErrInvalid
			}
			first = false
		}
		for _, c := range line {
			if c < 32 && c != '\t' {
				return ErrInvalid
			}
		}
	}
	if scanner.Err() != nil || first {
		return ErrInvalid
	}
	return nil
}
