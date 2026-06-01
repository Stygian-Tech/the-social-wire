import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

import { getAppEnv } from "@/lib/appEnv";
import {
  buildLatrGatewayServerAuthHeaders,
  hasLatrGatewayServerCredentials,
  LATR_GATEWAY_PROXY_FORWARDED_REQUEST_HEADERS,
  LATR_GATEWAY_PROXY_FORWARDED_RESPONSE_HEADERS,
  latrGatewayServerCredentialsHelpText,
  latrGatewayUpstreamBaseUrl,
} from "@/lib/latrGatewayProxyServer";

export const runtime = "nodejs";

type RouteContext = { params: Promise<{ path: string[] }> };

async function proxyLatrGateway(
  request: NextRequest,
  context: RouteContext
): Promise<NextResponse> {
  if (!hasLatrGatewayServerCredentials()) {
    return NextResponse.json(
      {
        error: "missing_client_credential",
        message: latrGatewayServerCredentialsHelpText(),
      },
      { status: 503 }
    );
  }

  const { path } = await context.params;
  const upstreamPath = `/${path.join("/")}${request.nextUrl.search}`;
  const upstreamUrl = `${latrGatewayUpstreamBaseUrl()}${upstreamPath}`;

  const headers = new Headers();
  for (const name of LATR_GATEWAY_PROXY_FORWARDED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  for (const [name, value] of Object.entries(buildLatrGatewayServerAuthHeaders())) {
    headers.set(name, value);
  }

  const body =
    request.method === "GET" || request.method === "HEAD"
      ? undefined
      : await request.arrayBuffer();

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl, {
      method: request.method,
      headers,
      body,
    });
  } catch {
    return NextResponse.json(
      { error: "gateway_unreachable", message: "L@tr gateway request failed." },
      { status: 502 }
    );
  }

  const responseHeaders = new Headers();
  for (const name of LATR_GATEWAY_PROXY_FORWARDED_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders.set(name, value);
  }

  const upstreamText = await upstream.text();
  if (upstream.status >= 400 && getAppEnv() !== "prod") {
    try {
      const upstreamError = (JSON.parse(upstreamText) as { error?: string }).error?.trim();
      if (upstreamError) {
        responseHeaders.set("X-Latr-Upstream-Error", upstreamError);
      }
    } catch {
      /* ignore non-JSON bodies */
    }
  }

  return new NextResponse(upstreamText, {
    status: upstream.status,
    headers: responseHeaders,
  });
}

export async function GET(request: NextRequest, context: RouteContext) {
  return proxyLatrGateway(request, context);
}

export async function POST(request: NextRequest, context: RouteContext) {
  return proxyLatrGateway(request, context);
}

export async function PATCH(request: NextRequest, context: RouteContext) {
  return proxyLatrGateway(request, context);
}

export async function DELETE(request: NextRequest, context: RouteContext) {
  return proxyLatrGateway(request, context);
}
