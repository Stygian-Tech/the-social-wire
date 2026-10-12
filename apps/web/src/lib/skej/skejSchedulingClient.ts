import { AppBskyRichtextFacet, RichText } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { postTextLength } from "@/lib/blueskyComposeClient";
import { getSkejEnvironment, type SKEJ_SCHEDULING_METHODS } from "./skejEnvironment";

export type SkejScheduleStatus = "draft" | "scheduled" | "blocked" | "publishing" | "published" | "failed" | "canceled";
export interface SkejScheduleRecord {
  $type: "at.skej.schedule";
  scheduledAt: string; status: SkejScheduleStatus; createdAt: string; updatedAt: string;
  timezonePolicy: string; userTimezone?: string; recordType: string; publishRkey: string;
  retry: { attemptCount: number; maxAttempts: number };
  posts: { text: string; publishRkey?: string; facets?: unknown[]; [key: string]: unknown }[];
  [key: string]: unknown;
}
export interface SkejScheduleSummary {
  rkey: string; did: string; scheduleUri: string; scheduledAt: string; status: SkejScheduleStatus;
  record: SkejScheduleRecord; attempts: number; lastError?: { message: string; code?: string }; publishedUri?: string;
}
export class SkejSchedulingError extends Error {
  constructor(message: string, readonly code: string, readonly status: number) { super(message); this.name = "SkejSchedulingError"; }
}
type Method = typeof SKEJ_SCHEDULING_METHODS[number];
type Actor = { session: OAuthSession; assertCurrentActor: () => void };

async function request(actor: Actor, method: Method, input?: unknown, signal?: AbortSignal): Promise<unknown> {
  actor.assertCurrentActor();
  const environment = getSkejEnvironment();
  const { data } = await createOAuthAgent(actor.session).com.atproto.server.getServiceAuth({ aud: environment.audience, lxm: method, exp: Math.floor(Date.now() / 1000) + 60 }, { signal });
  actor.assertCurrentActor();
  if (!data.token) throw new Error("Scheduling Authorization Is Unavailable.");
  const url = new URL(`/xrpc/${method}`, environment.api);
  if (!input && method === "at.skej.schedule.list") url.searchParams.set("accountDid", actor.session.did);
  const response = await fetch(url, { method: input ? "POST" : "GET", headers: { Authorization: `Bearer ${data.token}`, ...(input ? { "Content-Type": "application/json" } : {}) }, body: input ? JSON.stringify(input) : undefined, signal, credentials: "omit", redirect: "error" });
  actor.assertCurrentActor();
  const body = await response.json().catch(() => null) as Record<string, unknown> | null;
  if (!response.ok) {
    const code = typeof body?.error === "string" ? body.error : "Unavailable";
    const needsConnection = code.replace(/[^a-z]/gi, "").toLowerCase() === "accountneedsreauth";
    throw new SkejSchedulingError(needsConnection ? "Connect This Account to Skej to Enable Scheduling." : "Skej Could Not Complete This Request. Please Try Again.", code, response.status);
  }
  return body;
}
function summary(value: unknown, did: string): SkejScheduleSummary {
  const item = value as Partial<SkejScheduleSummary> | null;
  if (!item || item.did !== did || typeof item.rkey !== "string" || !/^[a-zA-Z0-9._~:-]{1,512}$/.test(item.rkey) || item.scheduleUri !== `at://${did}/at.skej.schedule/${item.rkey}` || !Number.isFinite(Date.parse(item.scheduledAt || "")) || !["draft", "scheduled", "blocked", "publishing", "published", "failed", "canceled"].includes(item.status || "") || !item.record || item.record.$type !== "at.skej.schedule" || !Array.isArray(item.record.posts) || item.record.posts.some(post => typeof post.text !== "string")) throw new Error("Skej Returned an Invalid Scheduled Post.");
  return item as SkejScheduleSummary;
}
export function validateScheduledAt(value: string, now = Date.now()): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.getTime() < now + 60_000) throw new Error("Choose a Time At Least One Minute From Now.");
  return date.toISOString();
}
export async function getSkejSchedulingReadiness(actor: Actor, signal?: AbortSignal) {
  try {
    const viewer = await request(actor, "at.skej.actor.getSession", undefined, signal) as { did?: unknown };
    if (viewer.did !== actor.session.did) throw new Error("The Scheduling Account Does Not Match.");
    return { accountDid: actor.session.did, connected: true };
  } catch (error) {
    if (error instanceof SkejSchedulingError && error.code.replace(/[^a-z]/gi, "").toLowerCase() === "accountneedsreauth") return { accountDid: actor.session.did, connected: false };
    throw error;
  }
}
export async function listSkejSchedules(actor: Actor, signal?: AbortSignal): Promise<SkejScheduleSummary[]> {
  const body = await request(actor, "at.skej.schedule.list", undefined, signal) as { records?: unknown };
  if (!Array.isArray(body.records) || body.records.length > 1000) throw new Error("Skej Returned an Invalid Content Calendar.");
  return body.records.map(item => summary(item, actor.session.did));
}
export async function createSkejSchedule(actor: Actor, text: string, scheduledAt: string): Promise<SkejScheduleSummary> {
  const length = postTextLength(text);
  if (!text.trim() || length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts Must Contain 1–300 Characters and At Most 3,000 UTF-8 Bytes.");
  const scheduled = validateScheduledAt(scheduledAt);
  actor.assertCurrentActor();
  const rich = new RichText({ text }); await rich.detectFacets(createAuthenticatedAppViewAgent(actor.session)); actor.assertCurrentActor();
  const facets = rich.facets?.map(facet => ({ ...facet, features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")) })).filter(facet => facet.features.length);
  const now = new Date().toISOString(), publishRkey = crypto.randomUUID();
  const record: SkejScheduleRecord = { $type: "at.skej.schedule", scheduledAt: scheduled, timezonePolicy: "absolute_utc", userTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone, createdAt: now, updatedAt: now, status: "scheduled", recordType: "app.bsky.feed.post", publishRkey, retry: { attemptCount: 0, maxAttempts: 8 }, posts: [{ text, publishRkey, ...(facets?.length ? { facets } : {}) }] };
  return summary(await request(actor, "at.skej.schedule.create", { accountDid: actor.session.did, record }), actor.session.did);
}
function assertEditable(actor: Actor, item: SkejScheduleSummary) {
  actor.assertCurrentActor(); summary(item, actor.session.did);
  if (!["draft", "scheduled", "blocked", "failed"].includes(item.status)) throw new Error("This Post Can No Longer Be Changed.");
}
export async function cancelSkejSchedule(actor: Actor, item: SkejScheduleSummary) {
  assertEditable(actor, item); return summary(await request(actor, "at.skej.schedule.cancel", { accountDid: actor.session.did, rkey: item.rkey }), actor.session.did);
}
export async function rescheduleSkejPost(actor: Actor, item: SkejScheduleSummary, scheduledAt: string) {
  assertEditable(actor, item);
  const record = { ...item.record, scheduledAt: validateScheduledAt(scheduledAt), updatedAt: new Date().toISOString(), status: "scheduled" };
  return summary(await request(actor, "at.skej.schedule.update", { accountDid: actor.session.did, rkey: item.rkey, record }), actor.session.did);
}
