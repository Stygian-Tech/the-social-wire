import { randomUUID } from "node:crypto";

import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

import { getAppEnv } from "@/lib/appEnv";
import {
  dummyLatrGatewaySavedItemsResponse,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";
import {
  buildLatrGatewayServerAuthHeaders,
  hasLatrGatewayServerCredentials,
  LATR_FORWARDED_AUTHORIZATION_HEADER,
  LATR_FORWARDED_DPOP_HEADER,
  LATR_GATEWAY_PROXY_FORWARDED_REQUEST_HEADERS,
  LATR_GATEWAY_PROXY_FORWARDED_RESPONSE_HEADERS,
  LATR_GATEWAY_UPSTREAM_DPOP_HEADER,
  latrGatewayServerCredentialsHelpText,
  latrGatewayUpstreamBaseUrl,
} from "@/lib/latrGatewayProxyServer";

export const runtime = "nodejs";

type RouteContext = { params: Promise<{ path: string[] }> };

function authorizationScheme(value: string | null): string {
  const trimmed = value?.trim();
  if (!trimmed) return "missing";
  const separator = trimmed.indexOf(" ");
  return separator > 0 ? trimmed.slice(0, separator) : "present";
}

function firstHeaderValue(value: string | null): string | undefined {
  const first = value?.split(",", 1)[0]?.trim();
  return first || undefined;
}

function forwardedProto(request: NextRequest): string {
  const forwarded = firstHeaderValue(
    request.headers.get("x-forwarded-proto")
  )?.toLowerCase();
  if (forwarded === "http" || forwarded === "https") return forwarded;
  return request.nextUrl.protocol.replace(":", "");
}

function publicRequestHost(request: NextRequest): string {
  return (
    firstHeaderValue(request.headers.get("x-forwarded-host")) ??
    request.nextUrl.host
  );
}

function requestId(request: NextRequest): string {
  return (
    firstHeaderValue(request.headers.get("x-request-id")) ??
    firstHeaderValue(request.headers.get("x-railway-request-id")) ??
    randomUUID()
  );
}

function responseErrorCode(body: string): string | undefined {
  try {
    return (JSON.parse(body) as { error?: string }).error?.trim();
  } catch {
    return undefined;
  }
}

async function proxyLatrGateway(
  request: NextRequest,
  context: RouteContext
): Promise<NextResponse> {
  const { path } = await context.params;
  if (
    request.method === "GET" &&
    path.join("/") === "v1/latr/saves" &&
    getAppEnv() !== "prod" &&
    isDummyReaderDataEnabled()
  ) {
    return NextResponse.json(dummyLatrGatewaySavedItemsResponse(), {
      headers: { "X-Social-Wire-Local-Sample": "latr-gateway" },
    });
  }

  if (!hasLatrGatewayServerCredentials()) {
    return NextResponse.json(
      {
        error: "missing_client_credential",
        message: latrGatewayServerCredentialsHelpText(),
      },
      { status: 503 }
    );
  }

  const upstreamPath = `/${path.join("/")}${request.nextUrl.search}`;
  const upstreamUrl = `${latrGatewayUpstreamBaseUrl()}${upstreamPath}`;
  const upstreamOrigin = new URL(upstreamUrl).origin;
  const upstreamForwardedHost = new URL(upstreamUrl).host;
  const publicForwardedProto = forwardedProto(request);
  const browserFacingHost = publicRequestHost(request);
  const originalUri = request.nextUrl.pathname + request.nextUrl.search;

  const headers = new Headers();
  for (const name of LATR_GATEWAY_PROXY_FORWARDED_REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (!value) continue;
    if (name === "authorization") {
      headers.set("Authorization", value);
      headers.set(LATR_FORWARDED_AUTHORIZATION_HEADER, value);
    } else if (name === "dpop") {
      // Preserve the browser-to-Web proof for deployments that reconstruct the
      // original public proxy URL, but do not leave it as the proof for the
      // Web-to-L@tr hop. That proof is bound to this same-origin proxy URL.
      headers.set(LATR_FORWARDED_DPOP_HEADER, value);
    } else if (name === LATR_GATEWAY_UPSTREAM_DPOP_HEADER) {
      // The browser minted this proof for the concrete api.*.latr.link URL.
      // L@tr verifies its primary DPoP header against that upstream request.
      headers.set("DPoP", value);
    } else if (name === "x-atproto-upstream-dpop") {
      headers.set("X-ATProto-Upstream-DPoP", value);
    } else if (name === "content-type") {
      headers.set("Content-Type", value);
    } else if (name === "accept") {
      headers.set("Accept", value);
    } else {
      headers.set(name, value);
    }
  }
  // L@tr combines these forwarded values when reconstructing the URL bound to
  // its primary DPoP proof. Keep Railway's browser-facing scheme, but use the
  // concrete L@tr authority rather than the Social Wire proxy authority.
  headers.set("X-Forwarded-Host", upstreamForwardedHost);
  headers.set("X-Forwarded-Proto", publicForwardedProto);
  headers.set("X-Original-URI", originalUri);
  for (const [name, value] of Object.entries(buildLatrGatewayServerAuthHeaders())) {
    headers.set(name, value);
  }
  const authDebug = {
    inAuth: authorizationScheme(request.headers.get("authorization")),
    inDpop: request.headers.has("dpop") ? "present" : "missing",
    inLatrDpop: request.headers.has(LATR_GATEWAY_UPSTREAM_DPOP_HEADER)
      ? "present"
      : "missing",
    inUpstreamDpop: request.headers.has("x-atproto-upstream-dpop")
      ? "present"
      : "missing",
    outAuth: authorizationScheme(headers.get("Authorization")),
    outDpop: headers.has("DPoP") ? "present" : "missing",
    outUpstreamDpop: headers.has("X-ATProto-Upstream-DPoP")
      ? "present"
      : "missing",
    outForwardedDpop: headers.has(LATR_FORWARDED_DPOP_HEADER)
      ? "present"
      : "missing",
  };

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
  const upstreamError = responseErrorCode(upstreamText);
  if (upstreamError === "invalid_dpop") {
    console.warn("[latr-gateway] upstream invalid_dpop", {
      requestId: requestId(request),
      method: request.method,
      proxyPath: request.nextUrl.pathname,
      upstreamOrigin,
      forwardedProto: publicForwardedProto,
      forwardedHost: upstreamForwardedHost,
      browserFacingHost,
      proofHeaders: {
        browserToWeb: request.headers.has("dpop"),
        latrGateway: request.headers.has(LATR_GATEWAY_UPSTREAM_DPOP_HEADER),
        viewerPds: request.headers.has("x-atproto-upstream-dpop"),
      },
    });
  }
  if (upstream.status >= 400 && getAppEnv() !== "prod") {
    responseHeaders.set(
      "X-Latr-Proxy-Auth-Debug",
      Object.entries(authDebug)
        .map(([key, value]) => `${key}:${value}`)
        .join(";")
    );
    if (upstreamError) {
      responseHeaders.set("X-Latr-Upstream-Error", upstreamError);
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
