import type { OAuthSession } from "@atproto/oauth-client-browser";

/** PDS XRPC method the gateway write-through path uses for a gateway route. */
export function pdsXrpcMethodForGatewayRequest(
  gatewayMethod: string,
  gatewayPath: string
): { xrpcMethod: string; httpMethod: "GET" | "POST" } | null {
  const method = gatewayMethod.toUpperCase();
  const path = gatewayPath.startsWith("/") ? gatewayPath : `/${gatewayPath}`;

  if (method === "GET" && path === "/v1/latr/saves") {
    return { xrpcMethod: "com.atproto.repo.listRecords", httpMethod: "GET" };
  }
  if (method === "GET" && path.startsWith("/v1/latr/saves/subject")) {
    return { xrpcMethod: "com.atproto.repo.getRecord", httpMethod: "GET" };
  }
  if (method === "POST" && path === "/v1/latr/saves") {
    return { xrpcMethod: "com.atproto.repo.createRecord", httpMethod: "POST" };
  }
  if (method === "PATCH" && path.includes("/v1/latr/saves/") && path.endsWith("/state")) {
    return { xrpcMethod: "com.atproto.repo.putRecord", httpMethod: "POST" };
  }
  if (method === "DELETE" && path.startsWith("/v1/latr/saves/")) {
    return { xrpcMethod: "com.atproto.repo.deleteRecord", httpMethod: "POST" };
  }
  return null;
}

function stripQueryAndFragment(url: string): string {
  const fragmentIndex = url.indexOf("#");
  const queryIndex = url.indexOf("?");
  if (fragmentIndex === -1 && queryIndex === -1) return url;
  if (fragmentIndex === -1) return url.slice(0, queryIndex);
  if (queryIndex === -1) return url.slice(0, fragmentIndex);
  return url.slice(0, Math.min(fragmentIndex, queryIndex));
}

async function sha256Base64Url(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const view = new Uint8Array(digest);
  let binary = "";
  for (const byte of view) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

type TokenSet = {
  access_token: string;
};

type SessionWithTokenSet = OAuthSession & {
  getTokenSet(refresh: boolean | "auto"): Promise<TokenSet>;
};

/** Mint a PDS-bound DPoP proof for gateway write-through (`X-ATProto-Upstream-DPoP`). */
export async function createUpstreamDpopProof(
  oauthSession: OAuthSession,
  xrpcMethod: string,
  httpMethod: "GET" | "POST"
): Promise<string> {
  const tokenInfo = await oauthSession.getTokenInfo();
  const pdsBase = tokenInfo.aud.replace(/\/$/, "");
  const htu = stripQueryAndFragment(`${pdsBase}/xrpc/${xrpcMethod}`);

  const tokenSet = await (oauthSession as SessionWithTokenSet).getTokenSet("auto");
  const ath = await sha256Base64Url(tokenSet.access_token);

  const key = oauthSession.server.dpopKey;
  const jwk = key.bareJwk;
  if (!jwk) {
    throw new Error("OAuth session DPoP key is unavailable");
  }

  const supported =
    oauthSession.server.serverMetadata.dpop_signing_alg_values_supported;
  const alg =
    supported?.find((candidate) => key.algorithms.includes(candidate)) ??
    key.algorithms[0];
  if (!alg) {
    throw new Error("OAuth session DPoP key has no supported algorithm");
  }

  const now = Math.floor(Date.now() / 1000);
  return key.createJwt(
    { alg, typ: "dpop+jwt", jwk },
    {
      iat: now,
      jti: Math.random().toString(36).slice(2),
      htm: httpMethod,
      htu,
      ath,
    }
  );
}
