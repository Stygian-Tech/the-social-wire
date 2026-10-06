import { expect, it } from "bun:test";
import { podcastArtworkFallback } from "@/lib/podcasts/artwork";

const original = "https://img-upload-production.transistor.fm/show/48255/1704319857-artwork.jpg";
const transformed = (source: string) => `https://img.transistorcdn.com/signature/rs:fill:0:0:1/mb:500000/${btoa(source).replace(/=+$/, "").match(/.{1,16}/g)?.join("/")}.jpg`;

it("recovers the original publisher image from chunked Transistor artwork", () => {
  expect(podcastArtworkFallback(transformed(original))).toBe(original);
});

it("rejects malformed artwork and decoded URLs outside the publisher upload host", () => {
  for (const source of ["https://example.com/art.jpg", "https://img.transistorcdn.com/bad.jpg", transformed("https://localhost/show/a.jpg"), transformed("https://img-upload-production.transistor.fm.evil.com/show/a.jpg"), transformed("https://user:secret@img-upload-production.transistor.fm/show/a.jpg"), transformed("https://img-upload-production.transistor.fm/show/a.jpg#fragment"), transformed("http://img-upload-production.transistor.fm/show/a.jpg")]) {
    expect(podcastArtworkFallback(source)).toBeUndefined();
  }
});
