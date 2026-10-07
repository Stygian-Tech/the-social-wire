package podcastcore

import (
	"bytes"
	"sort"
)

const MaximumID3TagBytes = 4 * 1024 * 1024
const MaximumID3ImageBytes = 1024 * 1024

// ID3TagByteCount accepts only bounded ID3v2.3/v2.4 prefixes without whole-tag
// unsynchronization. Count includes the ten-byte header.
func ID3TagByteCount(header []byte) (int, bool) {
	if len(header) < 10 || !bytes.Equal(header[:3], []byte("ID3")) || header[3] != 3 && header[3] != 4 || header[4] == 255 || header[5]&0x80 != 0 {
		return 0, false
	}
	mask := byte(0x1f)
	if header[3] == 4 {
		mask = 0x0f
	}
	if header[5]&mask != 0 {
		return 0, false
	}
	size, ok := id3Integer(header, 6, true)
	if !ok || size <= 0 || size > MaximumID3TagBytes-10 {
		return 0, false
	}
	return size + 10, true
}

// ParseID3ChapterArtwork extracts raster APIC pictures inside CHAP frames. A
// top-level cover image is never substituted for individual chapter artwork.
func ParseID3ChapterArtwork(data []byte) []ID3ChapterArtwork {
	out := []ID3ChapterArtwork{}
	count, ok := ID3TagByteCount(data)
	if !ok || len(data) < count {
		return out
	}
	data = data[:count]
	version := data[3]
	offset := 10
	if data[5]&0x40 != 0 {
		size, ok := id3Integer(data, offset, version == 4)
		if !ok {
			return out
		}
		minimum := 6
		if version == 3 {
			size += 4
			minimum = 10
		}
		if size < minimum || size > count-offset {
			return out
		}
		offset += size
	}
	for frames := 0; offset+10 <= count && frames < 4096 && len(out) < 1000; frames++ {
		frame, ok := id3ReadFrame(data, offset, count, version)
		if !ok {
			break
		}
		if frame.id == "CHAP" && frame.supported {
			if artwork, ok := id3Chapter(data, frame.start, frame.end, version); ok {
				out = append(out, artwork)
			}
		}
		offset = frame.end
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].StartSeconds < out[j].StartSeconds })
	return out
}
func id3Integer(data []byte, offset int, synchsafe bool) (int, bool) {
	if offset < 0 || offset > len(data)-4 {
		return 0, false
	}
	value := 0
	shift := 8
	if synchsafe {
		shift = 7
	}
	for _, b := range data[offset : offset+4] {
		if synchsafe && b&0x80 != 0 {
			return 0, false
		}
		value = value<<shift | int(b)
	}
	return value, true
}

type id3Frame struct {
	id         string
	start, end int
	supported  bool
}

func id3ReadFrame(data []byte, offset, end int, version byte) (id3Frame, bool) {
	if offset < 0 || end > len(data) || offset > end-10 {
		return id3Frame{}, false
	}
	for _, b := range data[offset : offset+4] {
		if !(b >= 'A' && b <= 'Z' || b >= '0' && b <= '9') {
			return id3Frame{}, false
		}
	}
	size, ok := id3Integer(data, offset+4, version == 4)
	if !ok || size <= 0 || size > end-offset-10 {
		return id3Frame{}, false
	}
	return id3Frame{string(data[offset : offset+4]), offset + 10, offset + 10 + size, data[offset+9] == 0}, true
}
func id3Chapter(data []byte, start, end int, version byte) (ID3ChapterArtwork, bool) {
	terminator := bytes.IndexByte(data[start:min(end, start+1024)], 0)
	if terminator < 0 {
		return ID3ChapterArtwork{}, false
	}
	terminator += start
	if terminator+17 > end {
		return ID3ChapterArtwork{}, false
	}
	milliseconds, ok := id3Integer(data, terminator+1, false)
	if !ok || milliseconds == 0xffffffff {
		return ID3ChapterArtwork{}, false
	}
	offset := terminator + 17
	for frames := 0; offset+10 <= end && frames < 256; frames++ {
		frame, ok := id3ReadFrame(data, offset, end, version)
		if !ok {
			return ID3ChapterArtwork{}, false
		}
		if frame.id == "APIC" && frame.supported {
			if image, mime, ok := id3Picture(data, frame.start, frame.end); ok {
				return ID3ChapterArtwork{float64(milliseconds) / 1000, image, mime}, true
			}
		}
		offset = frame.end
	}
	return ID3ChapterArtwork{}, false
}
func id3Picture(data []byte, start, end int) ([]byte, string, bool) {
	if end-start < 4 || data[start] > 3 {
		return nil, "", false
	}
	mimeEnd := bytes.IndexByte(data[start+1:min(end, start+129)], 0)
	if mimeEnd < 0 {
		return nil, "", false
	}
	mimeEnd += start + 1
	if mimeEnd+2 >= end || string(data[start+1:mimeEnd]) == "-->" {
		return nil, "", false
	}
	offset := mimeEnd + 2
	limit := min(end, offset+1024)
	if data[start] == 1 || data[start] == 2 {
		for offset+1 < limit && (data[offset] != 0 || data[offset+1] != 0) {
			offset += 2
		}
		if offset+1 >= limit {
			return nil, "", false
		}
		offset += 2
	} else {
		terminator := bytes.IndexByte(data[offset:limit], 0)
		if terminator < 0 {
			return nil, "", false
		}
		offset += terminator + 1
	}
	if offset >= end || end-offset > MaximumID3ImageBytes {
		return nil, "", false
	}
	mime := ImageMIME(data[offset:end])
	if mime == "" {
		return nil, "", false
	}
	return bytes.Clone(data[offset:end]), mime, true
}
