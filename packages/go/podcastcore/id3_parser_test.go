package podcastcore

import (
	"encoding/base64"
	"testing"
)

var id3TestPNG, _ = base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5X8AAAAASUVORK5CYII=")

func id3TestInteger(value int, synchsafe bool) []byte {
	shift, mask := 8, 255
	if synchsafe {
		shift, mask = 7, 127
	}
	out := []byte{}
	for n := 3; n >= 0; n-- {
		out = append(out, byte(value>>(n*shift)&mask))
	}
	return out
}
func id3TestFrame(id string, body []byte, version, flags byte) []byte {
	out := append([]byte(id), id3TestInteger(len(body), version == 4)...)
	out = append(out, 0, flags)
	return append(out, body...)
}
func id3TestChapter(milliseconds int, version, encoding, flags byte, image []byte) []byte {
	description := []byte{0}
	if encoding == 1 {
		description = []byte{255, 254, 65, 0, 0, 0}
	}
	apic := append([]byte{encoding}, []byte("image/png")...)
	apic = append(apic, 0, 3)
	apic = append(apic, description...)
	apic = append(apic, image...)
	body := []byte{'c', 0}
	for _, n := range []int{milliseconds, milliseconds + 1000, 0xffffffff, 0xffffffff} {
		body = append(body, id3TestInteger(n, false)...)
	}
	body = append(body, id3TestFrame("TIT2", []byte{0, 'x'}, version, 0)...)
	body = append(body, id3TestFrame("APIC", apic, version, flags)...)
	return id3TestFrame("CHAP", body, version, 0)
}
func id3TestTag(body []byte, version, flags byte) []byte {
	header := []byte{'I', 'D', '3', version, 0, flags}
	header = append(header, id3TestInteger(len(body), true)...)
	return append(header, body...)
}
func TestID3ChapterArtworkPreservesVersionAndEncodingParity(t *testing.T) {
	for _, version := range []byte{3, 4} {
		data := id3TestTag(append(id3TestChapter(2500, version, 0, 0, id3TestPNG), id3TestChapter(0, version, 1, 0, id3TestPNG)...), version, 0)
		count, ok := ID3TagByteCount(data[:10])
		if !ok || count != len(data) {
			t.Fatal(version, count)
		}
		images := ParseID3ChapterArtwork(data)
		if len(images) != 2 || images[0].StartSeconds != 0 || images[1].StartSeconds != 2.5 || images[0].MIMEType != "image/png" || string(images[0].Data) != string(id3TestPNG) {
			t.Fatal(version, images)
		}
	}
}
func TestID3RejectsMalformedActiveAndOversizedFrames(t *testing.T) {
	valid := id3TestTag(id3TestChapter(0, 3, 0, 0, id3TestPNG), 3, 0)
	tests := [][]byte{valid[:len(valid)-1], id3TestTag(id3TestChapter(0, 3, 0, 0, id3TestPNG), 3, 0x80), id3TestTag(id3TestChapter(0, 3, 0, 0, []byte("<svg><script/></svg>")), 3, 0), id3TestTag(id3TestChapter(0, 3, 0, 0, append(id3TestPNG, make([]byte, MaximumID3ImageBytes)...)), 3, 0), id3TestTag(id3TestFrame("CHAP", []byte{1, 2, 3}, 3, 0), 3, 0)}
	for n, data := range tests {
		if images := ParseID3ChapterArtwork(data); len(images) != 0 {
			t.Fatal(n, len(images))
		}
	}
	for _, header := range [][]byte{{'I', 'D', '3', 3, 0, 0, 128, 0, 0, 0}, append([]byte{'I', 'D', '3', 3, 0, 0}, id3TestInteger(MaximumID3TagBytes, true)...), {'I', 'D', '3', 2, 0, 0, 0, 0, 0, 1}} {
		if _, ok := ID3TagByteCount(header); ok {
			t.Fatal("accepted header")
		}
	}
	cover := id3TestFrame("APIC", append([]byte{0}, id3TestPNG...), 3, 0)
	data := id3TestTag(append(append(cover, id3TestChapter(0, 3, 0, 0x80, id3TestPNG)...), id3TestChapter(2000, 3, 0, 0, id3TestPNG)...), 3, 0)
	images := ParseID3ChapterArtwork(data)
	if len(images) != 1 || images[0].StartSeconds != 2 {
		t.Fatal(images)
	}
}
func TestID3ExtendedHeadersRemainInsideDeclaredTag(t *testing.T) {
	for _, version := range []byte{3, 4} {
		extended := append(id3TestInteger(6, false), make([]byte, 6)...)
		if version == 4 {
			extended = append(id3TestInteger(6, true), 1, 0)
		}
		tag := id3TestTag(append(extended, id3TestChapter(0, version, 0, 0, id3TestPNG)...), version, 0x40)
		if len(ParseID3ChapterArtwork(tag)) != 1 {
			t.Fatal(version)
		}
	}
}
func FuzzID3ChapterArtworkBounds(f *testing.F) {
	f.Add(id3TestTag(id3TestChapter(0, 3, 0, 0, id3TestPNG), 3, 0))
	f.Add([]byte("not an ID3 tag"))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > MaximumID3TagBytes+1 {
			t.Skip()
		}
		images := ParseID3ChapterArtwork(data)
		if len(images) > 1000 {
			t.Fatal("image count bound")
		}
		for _, v := range images {
			if len(v.Data) > MaximumID3ImageBytes || ImageMIME(v.Data) == "" {
				t.Fatal("image validation")
			}
		}
	})
}
