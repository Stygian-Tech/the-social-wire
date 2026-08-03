import { afterEach, describe, expect, it, mock } from "bun:test";
import { NextRequest } from "next/server";

import { GET } from "@/app/api/latr-gateway/[...path]/route";

const ORIG_FETCH = globalThis.fetch;
const ORIG_CONSOLE_WARN = console.warn;
const ORIG_ENV = {
  LATR_GATEWAY_CLIENT_CREDENTIAL: process.env.LATR_GATEWAY_CLIENT_CREDENTIAL,
  LATR_GATEWAY_CLIENT_ID: process.env.LATR_GATEWAY_CLIENT_ID,
  LATR_GATEWAY_API_KEY: process.env.LATR_GATEWAY_API_KEY,
  LATR_GATEWAY_URL: process.env.LATR_GATEWAY_URL,
  RAILWAY_PUBLIC_DOMAIN: process.env.RAILWAY_PUBLIC_DOMAIN,
  NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL,
  NEXT_PUBLIC_APP_ENV: process.env.NEXT_PUBLIC_APP_ENV,
  APP_ENV: process.env.APP_ENV,
  NEXT_PUBLIC_USE_DUMMY_DATA: process.env.NEXT_PUBLIC_USE_DUMMY_DATA,
};

function restoreEnv(): void {
  for (const [key, value] of Object.entries(ORIG_ENV)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

afterEach(() => {
  globalThis.fetch = ORIG_FETCH;
  console.warn = ORIG_CONSOLE_WARN;
  restoreEnv();
});

describe("GET /api/latr-gateway/[...path]", () => {
  it("serves the gateway response shape locally when credentials are unavailable", async () => {
    delete process.env.LATR_GATEWAY_CLIENT_CREDENTIAL;
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    process.env.NEXT_PUBLIC_APP_ENV = "local";
    process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "true";
    const fetchMock = mock(async () => new Response(null, { status: 500 }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const request = new NextRequest(
      "http://localhost:3000/api/latr-gateway/v1/latr/saves?sample=local",
    );
    const response = await GET(request, {
      params: Promise.resolve({ path: ["v1", "latr", "saves"] }),
    });
    const body = (await response.json()) as { records?: unknown[] };

    expect(response.status).toBe(200);
    expect(response.headers.get("X-Social-Wire-Local-Sample")).toBe(
      "latr-gateway",
    );
    expect(body.records?.length).toBeGreaterThan(0);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("forwards user auth headers to the hosted upstream and keeps credentials server-only", async () => {
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = "the-social-wire-web=official-secret";
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    delete process.env.LATR_GATEWAY_URL;
    process.env.RAILWAY_PUBLIC_DOMAIN = "testing.thesocialwire.app";
    process.env.NEXT_PUBLIC_APP_ENV = "test";

    let upstreamUrl: string | URL | Request | undefined;
    let upstreamHeaders = new Headers();
    const fetchMock = mock(async (url: string | URL | Request, init?: RequestInit) => {
      upstreamUrl = url;
      upstreamHeaders = new Headers(init?.headers);
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "DPoP-Nonce": "gateway-nonce",
          "X-Latr-Official-Client": "must-not-leak",
        },
      });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const req = new NextRequest(
      "http://web.railway.internal:3000/api/latr-gateway/v1/latr/saves?limit=25",
      {
        headers: {
          Authorization: "Bearer user-token",
          DPoP: "same-origin-proof",
          "X-Latr-Gateway-DPoP": "latr-gateway-proof",
          "X-ATProto-Upstream-DPoP": "pds-proof",
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-Forwarded-Host": "testing.thesocialwire.app",
          "X-Forwarded-Proto": "https",
        },
      }
    );

    const res = await GET(req, {
      params: Promise.resolve({ path: ["v1", "latr", "saves"] }),
    });

    expect(res.status).toBe(200);
    expect(String(upstreamUrl)).toBe(
      "https://api.testing.latr.link/v1/latr/saves?limit=25"
    );
    expect(upstreamHeaders.get("Authorization")).toBe("Bearer user-token");
    expect(upstreamHeaders.get("DPoP")).toBe("latr-gateway-proof");
    expect(upstreamHeaders.get("X-Latr-Forwarded-Authorization")).toBe(
      "Bearer user-token"
    );
    expect(upstreamHeaders.get("X-Latr-Forwarded-DPoP")).toBe(
      "same-origin-proof"
    );
    expect(upstreamHeaders.get("X-Latr-Gateway-DPoP")).toBeNull();
    expect(upstreamHeaders.get("X-ATProto-Upstream-DPoP")).toBe("pds-proof");
    expect(upstreamHeaders.get("X-Forwarded-Host")).toBe(
      "api.testing.latr.link"
    );
    expect(upstreamHeaders.get("X-Forwarded-Proto")).toBe("https");
    expect(upstreamHeaders.get("X-Original-URI")).toBe(
      "/api/latr-gateway/v1/latr/saves?limit=25"
    );
    expect(upstreamHeaders.get("Accept")).toBe("application/json");
    expect(upstreamHeaders.get("Content-Type")).toBe("application/json");
    expect(upstreamHeaders.get("X-Latr-Official-Client")).toBe("official-secret");
    expect(res.headers.get("DPoP-Nonce")).toBe("gateway-nonce");
    expect(res.headers.get("X-Latr-Official-Client")).toBeNull();
    expect(res.headers.get("X-Latr-Client-Id")).toBeNull();
    expect(res.headers.get("X-Latr-API-Key")).toBeNull();
  });

  it("uses the first trimmed forwarded protocol and the concrete L@tr host", async () => {
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = "the-social-wire-web=official-secret";
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    process.env.NEXT_PUBLIC_APP_ENV = "test";

    let upstreamHeaders = new Headers();
    globalThis.fetch = mock(async (_url, init) => {
      upstreamHeaders = new Headers(init?.headers);
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }) as unknown as typeof fetch;

    const req = new NextRequest(
      "http://web.railway.internal:3000/api/latr-gateway/v1/latr/saves",
      {
        headers: {
          "X-Forwarded-Host": " testing.thesocialwire.app, web.railway.internal ",
          "X-Forwarded-Proto": " HTTPS, http ",
        },
      }
    );

    const res = await GET(req, {
      params: Promise.resolve({ path: ["v1", "latr", "saves"] }),
    });

    expect(res.status).toBe(200);
    expect(upstreamHeaders.get("X-Forwarded-Host")).toBe(
      "api.testing.latr.link"
    );
    expect(upstreamHeaders.get("X-Forwarded-Proto")).toBe("https");
  });

  it("falls back to the request protocol when the forwarded protocol is invalid or missing", async () => {
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = "the-social-wire-web=official-secret";
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    process.env.NEXT_PUBLIC_APP_ENV = "test";

    const forwardedOrigins: Array<{
      host: string | null;
      proto: string | null;
    }> = [];
    globalThis.fetch = mock(async (_url, init) => {
      const headers = new Headers(init?.headers);
      forwardedOrigins.push({
        host: headers.get("X-Forwarded-Host"),
        proto: headers.get("X-Forwarded-Proto"),
      });
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }) as unknown as typeof fetch;

    for (const headers of [{ "X-Forwarded-Proto": "ftp" }, {}]) {
      const req = new NextRequest(
        "http://localhost:3000/api/latr-gateway/v1/latr/saves",
        { headers }
      );
      const res = await GET(req, {
        params: Promise.resolve({ path: ["v1", "latr", "saves"] }),
      });
      expect(res.status).toBe(200);
    }

    expect(forwardedOrigins).toEqual([
      { host: "api.testing.latr.link", proto: "http" },
      { host: "api.testing.latr.link", proto: "http" },
    ]);
  });

  it("emits non-prod auth forwarding diagnostics for upstream errors", async () => {
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = "the-social-wire-web=official-secret";
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    delete process.env.LATR_GATEWAY_URL;
    process.env.RAILWAY_PUBLIC_DOMAIN = "testing.thesocialwire.app";
    process.env.NEXT_PUBLIC_APP_ENV = "test";

    console.warn = mock(() => {}) as unknown as typeof console.warn;
    globalThis.fetch = mock(async () =>
      new Response(JSON.stringify({ error: "invalid_dpop" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      })
    ) as unknown as typeof fetch;

    const req = new NextRequest(
      "https://testing.thesocialwire.app/api/latr-gateway/v1/latr/saves",
      {
        headers: {
          Authorization: "Bearer user-token",
          DPoP: "same-origin-proof",
          "X-Latr-Gateway-DPoP": "latr-gateway-proof",
          "X-ATProto-Upstream-DPoP": "pds-proof",
        },
      }
    );

    const res = await GET(req, {
      params: Promise.resolve({ path: ["v1", "latr", "saves"] }),
    });

    expect(res.status).toBe(401);
    expect(res.headers.get("X-Latr-Upstream-Error")).toBe("invalid_dpop");
    expect(res.headers.get("X-Latr-Proxy-Auth-Debug")).toBe(
      "inAuth:Bearer;inDpop:present;inLatrDpop:present;inUpstreamDpop:present;outAuth:Bearer;outDpop:present;outUpstreamDpop:present;outForwardedDpop:present"
    );
  });

  it("logs sanitized invalid_dpop diagnostics in production without changing the upstream error", async () => {
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL =
      "the-social-wire-web=official-secret";
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    delete process.env.LATR_GATEWAY_URL;
    process.env.RAILWAY_PUBLIC_DOMAIN = "thesocialwire.app";
    process.env.NEXT_PUBLIC_APP_ENV = "prod";
    process.env.APP_ENV = "prod";

    const warnMock = mock(() => {});
    console.warn = warnMock as unknown as typeof console.warn;
    globalThis.fetch = mock(async () =>
      new Response(
        JSON.stringify({
          error: "invalid_dpop",
          message: "DPoP URL mismatch",
        }),
        {
          status: 401,
          headers: { "Content-Type": "application/json" },
        }
      )
    ) as unknown as typeof fetch;

    const req = new NextRequest(
      "http://web.railway.internal:3000/api/latr-gateway/v1/latr/saves",
      {
        headers: {
          Authorization: "DPoP super-secret-access-token",
          DPoP: "super-secret-same-origin-proof",
          "X-Latr-Gateway-DPoP": "super-secret-latr-proof",
          "X-ATProto-Upstream-DPoP": "super-secret-pds-proof",
          "X-Forwarded-Host": " thesocialwire.app, web.railway.internal ",
          "X-Forwarded-Proto": " https, http ",
          "X-Request-ID": "railway-request-id",
        },
      }
    );

    const res = await GET(req, {
      params: Promise.resolve({ path: ["v1", "latr", "saves"] }),
    });

    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({
      error: "invalid_dpop",
      message: "DPoP URL mismatch",
    });
    expect(res.headers.get("X-Latr-Proxy-Auth-Debug")).toBeNull();
    expect(res.headers.get("X-Latr-Upstream-Error")).toBeNull();
    expect(warnMock).toHaveBeenCalledWith(
      "[latr-gateway] upstream invalid_dpop",
      {
        requestId: "railway-request-id",
        method: "GET",
        proxyPath: "/api/latr-gateway/v1/latr/saves",
        upstreamOrigin: "https://api.latr.link",
        forwardedProto: "https",
        forwardedHost: "api.latr.link",
        browserFacingHost: "thesocialwire.app",
        proofHeaders: {
          browserToWeb: true,
          latrGateway: true,
          viewerPds: true,
        },
      }
    );
    expect(JSON.stringify(warnMock.mock.calls)).not.toContain("super-secret");
    expect(JSON.stringify(warnMock.mock.calls)).not.toContain("official-secret");
  });
});
