import { NextResponse } from "next/server";

import { buildWebOAuthClientMetadata } from "@/lib/oauthClientMetadata";

export const dynamic = "force-dynamic";

function requestOrigin(request: Request): string {
  const forwardedHost = request.headers.get("x-forwarded-host");
  if (forwardedHost) {
    const proto =
      request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() ??
      "https";
    const host = forwardedHost.split(",")[0]?.trim();
    if (host) return `${proto}://${host}`;
  }
  return new URL(request.url).origin;
}

export function GET(request: Request) {
  const metadata = buildWebOAuthClientMetadata(requestOrigin(request));
  return NextResponse.json(metadata, {
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "public, max-age=300",
    },
  });
}
