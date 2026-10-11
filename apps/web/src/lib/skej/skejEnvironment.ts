import { getAppEnv } from "@/lib/appEnv";

export function getSkejEnvironment() {
  const environment = getAppEnv();
  const production = environment === "prod";
  const fallback = production ? "https://api.skej.at" : "https://api.testing.skej.at";
  const api = new URL(environment === "local" ? process.env.NEXT_PUBLIC_LOCAL_SKEJ_API_URL || fallback : fallback);
  if (api.protocol !== "https:" || api.username || api.password || api.pathname !== "/" || api.search || api.hash) throw new Error("Scheduling Requires an HTTPS Skej Origin.");
  return { api: api.origin, audience: `did:web:${api.host.replaceAll(":", "%3A")}#skej_scheduler`, connectUrl: `${api.origin}/oauth/start` };
}

export const SKEJ_SCHEDULING_METHODS = ["at.skej.actor.getSession", "at.skej.schedule.list", "at.skej.schedule.create", "at.skej.schedule.update", "at.skej.schedule.cancel"] as const;
export const SKEJ_SCHEDULING_SCOPES = SKEJ_SCHEDULING_METHODS.map(method => `rpc:${method}?aud=did:web:api.skej.at%23skej_scheduler`);

export function skejScopesForEnvironment(scopes: string): string {
  return scopes.replaceAll("did:web:api.skej.at%23skej_scheduler", getSkejEnvironment().audience.replaceAll("#", "%23"));
}
