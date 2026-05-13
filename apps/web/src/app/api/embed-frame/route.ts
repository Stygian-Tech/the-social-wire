import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import {
  parseFramePolicy,
  validateHttpsEmbedProbeTarget,
} from "@/lib/embedFramePolicy";

const TIMEOUT_MS = 8_000;

function embeddingHostHintsFromRequest(req: NextRequest): string[] {
  const forwarded = req.headers.get("x-forwarded-host")?.split(",")[0]?.trim();
  const rawHost = forwarded || req.headers.get("host")?.trim() || "";
  const hints = new Set<string>();
  const host = rawHost.split(":")[0]?.trim().toLowerCase();
  if (host) hints.add(host);

  const vercelRaw = process.env.VERCEL_URL?.trim().toLowerCase();
  if (vercelRaw) {
    try {
      const vc = vercelRaw.includes("://")
        ? new URL(vercelRaw).hostname
        : vercelRaw.split(":")[0]?.trim();
      if (vc) hints.add(vc.toLowerCase());
    } catch {
      const vc = vercelRaw.split(":")[0]?.trim();
      if (vc) hints.add(vc);
    }
  }
  return [...hints];
}

async function fetchFramingHeaders(targetHref: string): Promise<Response> {
  const init = {
    redirect: "follow" as const,
    signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: {
      "User-Agent": "the-social-wire/embed-frame-probe",
      Accept: "*/*",
    },
  };
  let res = await fetch(targetHref, { ...init, method: "HEAD" });
  if (res.status === 405 || res.status === 501) {
    res = await fetch(targetHref, {
      ...init,
      method: "GET",
      headers: {
        ...init.headers,
        Range: "bytes=0-0",
      },
    });
  }
  return res;
}

export async function GET(req: NextRequest) {
  const encoded = req.nextUrl.searchParams.get("url");
  if (encoded == null || encoded === "") {
    return NextResponse.json({ error: "missing url" }, { status: 400 });
  }

  let decoded: string;
  try {
    decoded = decodeURIComponent(encoded);
  } catch {
    return NextResponse.json({ error: "invalid url encoding" }, { status: 400 });
  }

  const validated = validateHttpsEmbedProbeTarget(decoded);
  if (!validated.ok) {
    return NextResponse.json({ error: "invalid url" }, { status: 400 });
  }

  let res: Response;
  try {
    res = await fetchFramingHeaders(validated.url.href);
  } catch {
    return NextResponse.json({ frameable: true, canonicalUrl: validated.url.href });
  }

  const xFrameOptions = res.headers.get("x-frame-options");
  const csp =
    res.headers.get("content-security-policy") ??
    res.headers.get("content-security-policy-report-only");

  const embeddingHostHints = embeddingHostHintsFromRequest(req);
  const { frameable } = parseFramePolicy({
    xFrameOptions,
    contentSecurityPolicy: csp,
    embeddingHostHints,
  });

  return NextResponse.json({
    frameable,
    canonicalUrl: res.url,
  });
}
