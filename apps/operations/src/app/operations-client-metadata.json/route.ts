import { NextResponse } from "next/server"
import { buildOperationsOAuthClientMetadata } from "@/lib/operations-oauth-client-metadata"

export const dynamic = "force-dynamic"

function requestOrigin(request: Request): string {
  const forwardedHost = request.headers.get("x-forwarded-host")?.split(",")[0]?.trim()
  if (forwardedHost) {
    const forwardedProto = request.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() || "https"
    return `${forwardedProto}://${forwardedHost}`
  }
  return new URL(request.url).origin
}

export function GET(request: Request) {
  return NextResponse.json(buildOperationsOAuthClientMetadata(requestOrigin(request)), {
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "public, max-age=300",
    },
  })
}
