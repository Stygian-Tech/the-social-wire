import type { OAuthSession } from "@atproto/oauth-client-browser";

export function gatewayBaseUrl(): string {
  return (
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL ?? "https://api.thesocialwire.app"
  ).replace(/\/$/, "");
}

export async function gatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit
): Promise<Response> {
  const url = `${gatewayBaseUrl()}${path.startsWith("/") ? path : `/${path}`}`;
  return oauthSession.fetchHandler(url, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init?.headers ?? {}),
    },
  });
}
