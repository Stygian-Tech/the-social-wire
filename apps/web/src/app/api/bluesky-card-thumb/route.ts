import { NextResponse } from "next/server";

import { validateHttpsEmbedProbeTarget } from "@/lib/embedFramePolicy";

export const runtime = "nodejs";

const MAX_THUMB_BYTES = 1_000_000;
const MAX_ORIGINAL_BYTES = 10_000_000;

async function readLimitedBody(
  body: ReadableStream<Uint8Array>,
  maxBytes: number,
): Promise<Uint8Array | null> {
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }

  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const original = params.get("purpose") === "original";
  const maxBytes = original ? MAX_ORIGINAL_BYTES : MAX_THUMB_BYTES;
  const rawUrl = params.get("url") ?? "";
  const validated = validateHttpsEmbedProbeTarget(rawUrl);
  if (!validated.ok) {
    return NextResponse.json({ error: "invalid_url" }, { status: 400 });
  }

  let target = validated.url;
  let upstream: Response;
  const signal = AbortSignal.any([request.signal, AbortSignal.timeout(15_000)]);
  try {
    for (let redirects = 0; ; redirects++) {
      upstream = await fetch(target, {
        headers: {
          Accept:
            "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.1",
          "User-Agent": "The Social Wire image fetcher",
        },
        // Original-image redirects must retain the public HTTPS target policy.
        redirect: original ? "manual" : "follow",
        signal,
      });
      if (!original || ![301, 302, 303, 307, 308].includes(upstream.status))
        break;
      const location = upstream.headers.get("location");
      await upstream.body?.cancel();
      if (!location || redirects >= 3)
        return NextResponse.json(
          { error: "invalid_redirect" },
          { status: 502 },
        );
      const next = validateHttpsEmbedProbeTarget(
        new URL(location, target).href,
      );
      if (!next.ok)
        return NextResponse.json(
          { error: "invalid_redirect" },
          { status: 400 },
        );
      target = next.url;
    }
  } catch {
    return NextResponse.json({ error: "fetch_failed" }, { status: 502 });
  }

  if (!upstream.ok || !upstream.body) {
    return NextResponse.json({ error: "fetch_failed" }, { status: 502 });
  }

  const contentType =
    upstream.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() ??
    "";
  if (!contentType.startsWith("image/")) {
    return NextResponse.json({ error: "not_image" }, { status: 415 });
  }

  const contentLength = Number(upstream.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    return NextResponse.json({ error: "too_large" }, { status: 413 });
  }

  const body = await readLimitedBody(upstream.body, maxBytes);
  if (!body) {
    return NextResponse.json({ error: "too_large" }, { status: 413 });
  }

  const arrayBuffer = new ArrayBuffer(body.byteLength);
  new Uint8Array(arrayBuffer).set(body);
  return new Response(arrayBuffer, {
    headers: {
      "Cache-Control": "public, max-age=3600",
      "Content-Length": String(body.byteLength),
      "Content-Type": contentType,
    },
  });
}
