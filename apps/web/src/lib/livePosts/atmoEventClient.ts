import { ComAtprotoRepoStrongRef } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
export type AtmoEvent = { uri: string; cid: string; title: string; description?: string; startsAt?: string; endsAt?: string; status?: string; url: string };
const EVENT = "community.lexicon.calendar.event", RSVP = "community.lexicon.calendar.rsvp";
class MissingCalendarEvent extends Error {}
type RecordResult = { uri: string; cid: string; value: unknown };
function eventUri(uri: string): { did: string; rkey: string } {
  const match = /^at:\/\/(did:(?:plc:[a-z2-7]+|web:[^/?#\s]+))\/community\.lexicon\.calendar\.event\/([a-zA-Z0-9._~:-]+)$/.exec(uri);
  if (!match) throw new Error("Invalid atmo.rsvp event reference.");
  return { did: match[1], rkey: match[2] };
}
function datetime(value: unknown): value is string { return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value) && Number.isFinite(Date.parse(value)); }
export function parseAtmoEvent(record: RecordResult): AtmoEvent {
  eventUri(record.uri);
  if (!ComAtprotoRepoStrongRef.validateMain({ uri: record.uri, cid: record.cid }).success) throw new Error("Invalid atmo.rsvp event identity.");
  const value = record.value as Record<string, unknown>;
  if (!value || value.$type !== EVENT || typeof value.name !== "string" || !value.name.trim() || !datetime(value.createdAt)
    || (value.startsAt !== undefined && !datetime(value.startsAt)) || (value.endsAt !== undefined && !datetime(value.endsAt))
    || (typeof value.startsAt === "string" && typeof value.endsAt === "string" && Date.parse(value.endsAt) < Date.parse(value.startsAt))) throw new Error("Invalid atmo.rsvp calendar event.");
  const { did, rkey } = eventUri(record.uri);
  return { uri: record.uri, cid: record.cid, title: value.name.trim(), ...(typeof value.description === "string" ? { description: value.description } : {}), ...(typeof value.startsAt === "string" ? { startsAt: value.startsAt } : {}), ...(typeof value.endsAt === "string" ? { endsAt: value.endsAt } : {}), ...(typeof value.status === "string" ? { status: value.status } : {}), url: `https://atmo.rsvp/p/${encodeURIComponent(did)}/e/${encodeURIComponent(rkey)}` };
}
export function liveEventPhase(event: { startsAt?: string; endsAt?: string }, now = Date.now()): "current" | "upcoming" | "past" {
  const start = event.startsAt ? Date.parse(event.startsAt) : undefined, end = event.endsAt ? Date.parse(event.endsAt) : undefined;
  if (end !== undefined && Number.isFinite(end) && end <= now) return "past";
  if (start !== undefined && Number.isFinite(start) && start > now) return "upcoming";
  if (start !== undefined && Number.isFinite(start) && end === undefined) return "past";
  return "current";
}
async function listOwn(session: OAuthSession, collection: string, signal?: AbortSignal): Promise<RecordResult[]> {
  const agent = createOAuthAgent(session), records: RecordResult[] = [], seen = new Set<string>(); let cursor: string | undefined;
  do {
    signal?.throwIfAborted();
    const { data } = await agent.com.atproto.repo.listRecords({ repo: session.did, collection, limit: 100, cursor }, { signal });
    for (const record of data.records) { if (!record.uri.startsWith(`at://${session.did}/${collection}/`)) throw new Error("The PDS returned another account's calendar records."); records.push(record); }
    cursor = data.cursor; if (cursor && seen.has(cursor)) throw new Error("The PDS repeated a calendar cursor."); if (cursor) seen.add(cursor);
  } while (cursor);
  return records;
}
async function publicJSON(url: string, signal?: AbortSignal): Promise<unknown> {
  const response = await fetch(url, { signal, credentials: "omit", redirect: "error", headers: { Accept: "application/json" } });
  if (!response.ok) {
    if ([400, 404].includes(response.status) && new URL(url).pathname === "/xrpc/com.atproto.repo.getRecord") {
      const failure = await response.json().catch(() => undefined) as { error?: string } | undefined;
      if (failure?.error === "RecordNotFound") throw new MissingCalendarEvent("The referenced calendar event no longer exists.");
    }
    throw new Error(`Calendar discovery request failed (${response.status}).`);
  }
  return response.json();
}
async function getPublicEvent(uri: string, signal?: AbortSignal): Promise<RecordResult> {
  const { did, rkey } = eventUri(uri), network = getAtprotoNetwork();
  let didUrl: string;
  if (did.startsWith("did:plc:")) didUrl = `${network.plcDirectory}/${encodeURIComponent(did)}`;
  else {
    // Isolated local discovery must never fall back to a public DID-web host.
    if (network.plcDirectory !== "https://plc.directory") throw new Error("DID-web calendar discovery is unavailable in the isolated local network.");
    const parts = did.slice(8).split(":").map(decodeURIComponent), host = parts.shift()!;
    didUrl = `https://${host}/${parts.length ? `${parts.map(encodeURIComponent).join("/")}/did.json` : ".well-known/did.json"}`;
  }
  const doc = await publicJSON(didUrl, signal) as { id?: string; service?: { id?: string; type?: string; serviceEndpoint?: string }[] };
  if (doc.id !== did) throw new Error("Calendar author identity did not match its DID document.");
  const service = doc.service?.find(item => (item.id === "#atproto_pds" || item.id === `${did}#atproto_pds`) && item.type === "AtprotoPersonalDataServer");
  if (!service?.serviceEndpoint) throw new Error("The calendar author has no PDS endpoint.");
  const endpoint = new URL(service.serviceEndpoint);
  if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) throw new Error("The calendar author has an unsafe PDS endpoint.");
  if (network.plcDirectory !== "https://plc.directory") {
    const allowed = (process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CALENDAR_PDS_URLS ?? "").split(",").map(value => value.trim()).filter(Boolean).map(value => {
      const url = new URL(value);
      if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash) throw new Error("Local calendar PDS allowlist must contain HTTPS origins.");
      return url.origin;
    });
    if (!allowed.includes(endpoint.origin)) throw new Error("The calendar author PDS is not allowed in the isolated local network.");
  }
  const url = new URL("/xrpc/com.atproto.repo.getRecord", endpoint); url.search = new URLSearchParams({ repo: did, collection: EVENT, rkey }).toString();
  const record = await publicJSON(url.href, signal) as RecordResult;
  if (record.uri !== uri) throw new Error("The PDS returned another calendar event.");
  return record;
}
/** Personal discovery only: owned events plus the viewer's going/interested public RSVPs. */
export async function listViewerAtmoEvents(session: OAuthSession, signal?: AbortSignal): Promise<AtmoEvent[]> {
  const own = await listOwn(session, EVENT, signal), rsvps = await listOwn(session, RSVP, signal);
  const records = new Map(own.map(record => [record.uri, record])), selected = new Map<string, string>();
  for (const record of rsvps) {
    const value = record.value as { $type?: string; status?: string; subject?: { uri: string; cid: string } };
    if (value?.$type !== RSVP || !value.subject || !ComAtprotoRepoStrongRef.validateMain(value.subject).success) throw new Error("Invalid calendar RSVP record.");
    eventUri(value.subject.uri);
    const previous = selected.get(value.subject.uri);
    if (previous !== undefined && previous !== value.status) throw new Error("Conflicting RSVP statuses for the same event. Resolve duplicate RSVPs before importing.");
    selected.set(value.subject.uri, value.status ?? "");
  }
  for (const [uri, status] of selected) {
    if (![`${RSVP}#going`, `${RSVP}#interested`].includes(status) || records.has(uri)) continue;
    signal?.throwIfAborted();
    try { records.set(uri, await getPublicEvent(uri, signal)); } catch (error) { if (!(error instanceof MissingCalendarEvent)) throw error; }
  }
  return [...records.values()].map(parseAtmoEvent).filter(event => event.status !== `${EVENT}#cancelled`).sort((a, b) => ((a.startsAt ? Date.parse(a.startsAt) : Infinity) - (b.startsAt ? Date.parse(b.startsAt) : Infinity)) || a.uri.localeCompare(b.uri));
}
