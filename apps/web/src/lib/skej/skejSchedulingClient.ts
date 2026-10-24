import { compilePostText, resolvePostText } from "@/lib/composePostText";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { ArticleSchedulingNotSubmittedError } from "@/lib/articles/articleSchedulingError";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { composeExternalEmbed, type ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
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
export interface SkejArticleDocument extends Record<string, unknown> {
  $type: "site.standard.document";
  title: string;
  site: string;
  publishedAt: string;
}
export type SkejArticleScheduleSummary = SkejScheduleSummary & {
  record: SkejScheduleRecord & { recordType: "site.standard.document"; shadowRecord: SkejArticleDocument };
};
function isArticleDocument(value: unknown): value is SkejArticleDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return record.$type === "site.standard.document" && typeof record.title === "string" && !!record.title.trim()
    && typeof record.site === "string" && (/^at:\/\/[^/]+\/site\.standard\.publication\/[^/]+$/.test(record.site) || /^https:\/\//.test(record.site))
    && typeof record.publishedAt === "string" && Number.isFinite(Date.parse(record.publishedAt));
}
export function isSkejArticleSchedule(item: SkejScheduleSummary): item is SkejArticleScheduleSummary {
  return item.record.recordType === "site.standard.document" && item.record.posts.length === 0 && isArticleDocument(item.record.shadowRecord);
}
export class SkejSchedulingError extends Error {
  constructor(message: string, readonly code: string, readonly status: number) { super(message); this.name = "SkejSchedulingError"; }
}
type Method = typeof SKEJ_SCHEDULING_METHODS[number];
export type SkejSchedulingActor = { session: OAuthSession; assertCurrentActor: () => void };

async function request(actor: SkejSchedulingActor, method: Method, input?: unknown, signal?: AbortSignal): Promise<unknown> {
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
  actor.assertCurrentActor();
  if (!response.ok) {
    const code = typeof body?.error === "string" ? body.error : "Unavailable";
    const needsConnection = code.replace(/[^a-z]/gi, "").toLowerCase() === "accountneedsreauth";
    throw new SkejSchedulingError(needsConnection ? "Connect This Account to Skej to Enable Scheduling." : "Skej Could Not Complete This Request. Please Try Again.", code, response.status);
  }
  return body;
}
function summary(value: unknown, did: string): SkejScheduleSummary {
  const item = value as Partial<SkejScheduleSummary> | null;
  if (!item || item.did !== did || typeof item.rkey !== "string" || !/^[a-zA-Z0-9._~:-]{1,512}$/.test(item.rkey) || item.scheduleUri !== `at://${did}/at.skej.schedule/${item.rkey}` || !Number.isFinite(Date.parse(item.scheduledAt || "")) || !["draft", "scheduled", "blocked", "publishing", "published", "failed", "canceled"].includes(item.status || "") || !item.record || item.record.$type !== "at.skej.schedule" || !Array.isArray(item.record.posts) || item.record.posts.some(post => !post || typeof post.text !== "string")) throw new Error("Skej Returned an Invalid Scheduled Post.");
  if (item.record.recordType === "site.standard.document" && !isSkejArticleSchedule(item as SkejScheduleSummary)) throw new Error("Skej Returned an Invalid Scheduled Article.");
  return item as SkejScheduleSummary;
}
export function validateScheduledAt(value: string, now = Date.now()): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.getTime() < now + 60_000) throw new Error("Choose a Time At Least One Minute From Now.");
  return date.toISOString();
}
export async function getSkejSchedulingReadiness(actor: SkejSchedulingActor, signal?: AbortSignal) {
  try {
    const viewer = await request(actor, "at.skej.actor.getSession", undefined, signal) as { did?: unknown };
    if (viewer.did !== actor.session.did) throw new Error("The Scheduling Account Does Not Match.");
    return { accountDid: actor.session.did, connected: true };
  } catch (error) {
    if (error instanceof SkejSchedulingError && error.code.replace(/[^a-z]/gi, "").toLowerCase() === "accountneedsreauth") return { accountDid: actor.session.did, connected: false };
    throw error;
  }
}
export async function listSkejSchedules(actor: SkejSchedulingActor, signal?: AbortSignal): Promise<SkejScheduleSummary[]> {
  const body = await request(actor, "at.skej.schedule.list", undefined, signal) as { records?: unknown };
  if (!Array.isArray(body.records) || body.records.length > 1000) throw new Error("Skej Returned an Invalid Content Calendar.");
  return body.records.map(item => summary(item, actor.session.did));
}
export async function createSkejSchedule(actor: SkejSchedulingActor, text: string, scheduledAt: string, linkPreview?: ComposeLinkPreview): Promise<SkejScheduleSummary> {
  const length = postTextLength(text);
  if (!compilePostText(text).text.trim() || length.graphemes > 300 || length.bytes > 3000) throw new Error("Posts Must Contain 1–300 Characters and At Most 3,000 UTF-8 Bytes.");
  const scheduled = validateScheduledAt(scheduledAt);
  actor.assertCurrentActor();
  const compiled = await resolvePostText(text, createAuthenticatedAppViewAgent(actor.session));
  const facets = compiled.facets;
  actor.assertCurrentActor();
  const embed = await composeExternalEmbed(actor.session, text, linkPreview, actor.assertCurrentActor);
  actor.assertCurrentActor();
  const now = new Date().toISOString(), publishRkey = crypto.randomUUID();
  const record: SkejScheduleRecord = { $type: "at.skej.schedule", scheduledAt: scheduled, timezonePolicy: "absolute_utc", userTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone, createdAt: now, updatedAt: now, status: "scheduled", recordType: "app.bsky.feed.post", publishRkey, retry: { attemptCount: 0, maxAttempts: 8 }, posts: [{ text: compiled.text, publishRkey, ...(facets?.length ? { facets } : {}), ...(embed ? { embed } : {}) }] };
  return summary(await request(actor, "at.skej.schedule.create", { accountDid: actor.session.did, record }), actor.session.did);
}
function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => `${JSON.stringify(key)}:${canonicalJSON(child)}`).join(",")}}`;
  return JSON.stringify(value);
}

/** The payload is public in the user's at.skej.schedule record before publication. */
export async function createSkejArticleSchedule(actor: SkejSchedulingActor, preparedDocument: SkejArticleDocument, publishRkey: string, scheduledAt: string): Promise<SkejArticleScheduleSummary> {
  actor.assertCurrentActor();
  let scheduled: string;
  let document: SkejArticleDocument;
  try {
    scheduled = validateScheduledAt(scheduledAt);
    if (!isArticleDocument(preparedDocument) || !/^[a-zA-Z0-9._~:-]{1,512}$/.test(publishRkey) || publishRkey === "." || publishRkey === "..") throw new Error("The Prepared Article Is Invalid.");
    document = JSON.parse(JSON.stringify({ ...preparedDocument, publishedAt: scheduled, ...(preparedDocument.updatedAt !== undefined ? { updatedAt: scheduled } : {}) })) as SkejArticleDocument;
  } catch (error) {
    throw new ArticleSchedulingNotSubmittedError(error);
  }
  const findExisting = async () => {
    const schedules = await listSkejSchedules(actor);
    actor.assertCurrentActor();
    const matches = schedules.filter(item => item.record.recordType === "site.standard.document" && item.record.publishRkey === publishRkey && !(item.status === "canceled" && item.record.status === "canceled"));
    if (!matches.length) return undefined;
    const match = matches[0];
    if (matches.length !== 1 || !isSkejArticleSchedule(match) || match.record.status !== match.status || match.status === "canceled" || match.status === "published" || match.scheduledAt !== scheduled || canonicalJSON(match.record.shadowRecord) !== canonicalJSON(document)) throw new Error("This Article Already Has a Different Schedule. Refresh Scheduled Articles Before Continuing.");
    return match;
  };
  const existing = await findExisting();
  actor.assertCurrentActor();
  if (existing) return existing;
  const now = new Date().toISOString();
  const record: SkejScheduleRecord = { $type: "at.skej.schedule", title: [...document.title].slice(0, 120).join(""), scheduledAt: scheduled, timezonePolicy: "absolute_utc", userTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone, createdAt: now, updatedAt: now, status: "scheduled", recordType: "site.standard.document", publishRkey, shadowRecord: document, retry: { attemptCount: 0, maxAttempts: 8 }, posts: [] };
  try {
    const result = summary(await request(actor, "at.skej.schedule.create", { accountDid: actor.session.did, record }), actor.session.did);
    actor.assertCurrentActor();
    if (!isSkejArticleSchedule(result) || result.record.publishRkey !== publishRkey || result.scheduledAt !== scheduled || canonicalJSON(result.record.shadowRecord) !== canonicalJSON(document)) throw new Error("Skej Returned a Different Scheduled Article.");
    return result;
  } catch (error) {
    actor.assertCurrentActor();
    // Creation has no idempotency key. Read back, but never blindly repeat the mutation.
    if (error instanceof SkejSchedulingError && error.status < 500) throw error;
    const recovered = await findExisting();
    actor.assertCurrentActor();
    if (recovered) return recovered;
    throw error;
  }
}

function assertEditable(actor: SkejSchedulingActor, item: SkejScheduleSummary) {
  actor.assertCurrentActor(); summary(item, actor.session.did);
  if (!["draft", "scheduled", "blocked", "failed"].includes(item.status)) throw new Error("This Scheduled Content Can No Longer Be Changed.");
}
export async function cancelSkejSchedule(actor: SkejSchedulingActor, item: SkejScheduleSummary) {
  assertEditable(actor, item); return summary(await request(actor, "at.skej.schedule.cancel", { accountDid: actor.session.did, rkey: item.rkey }), actor.session.did);
}
export async function rescheduleSkejPost(actor: SkejSchedulingActor, item: SkejScheduleSummary, scheduledAt: string) {
  assertEditable(actor, item);
  const scheduled = validateScheduledAt(scheduledAt);
  const record = { ...item.record, scheduledAt: scheduled, updatedAt: new Date().toISOString(), status: "scheduled", ...(isSkejArticleSchedule(item) ? { shadowRecord: { ...item.record.shadowRecord, publishedAt: scheduled, ...(item.record.shadowRecord.updatedAt !== undefined ? { updatedAt: scheduled } : {}) } } : {}) };
  return summary(await request(actor, "at.skej.schedule.update", { accountDid: actor.session.did, rkey: item.rkey, record }), actor.session.did);
}
