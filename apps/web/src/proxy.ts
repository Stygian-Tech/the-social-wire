import { NextResponse } from "next/server";
import { toolsEnabled } from "@/lib/toolsEnabled";

/** Cover direct requests, nested routes, and client navigation to Tools. */
export function proxy() {
  if (!toolsEnabled()) {
    return new NextResponse("Not Found", {
      status: 404,
      headers: { "Cache-Control": "private, no-store" },
    });
  }
  return NextResponse.next();
}

export const config = {
  matcher: [
    "/articles/:path*",
    "/live-post/:path*",
    "/livestream/:path*",
    "/brand-accounts/:path*",
    "/content-calendar/:path*",
    "/analytics/:path*",
    "/scheduling/:path*",
  ],
};
