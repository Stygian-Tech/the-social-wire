package podcastcore

import "bytes"

// ImageMIME accepts source raster formats and never forwards active SVG or HTML.
func ImageMIME(data []byte) string {
	if len(data) < 24 {
		return ""
	}
	if bytes.HasPrefix(data, []byte{137, 80, 78, 71, 13, 10, 26, 10}) && string(data[12:16]) == "IHDR" {
		return "image/png"
	}
	if bytes.HasPrefix(data, []byte{255, 216, 255}) && bytes.HasSuffix(data, []byte{255, 217}) {
		return "image/jpeg"
	}
	if string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a" {
		return "image/gif"
	}
	if string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		return "image/webp"
	}
	if string(data[4:8]) == "ftyp" && (string(data[8:12]) == "avif" || string(data[8:12]) == "avis") {
		return "image/avif"
	}
	return ""
}
