import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";

export type ReadAgeOption = {
  days: number;
  before: string;
  count: number;
};

export type ReadAgeOptionsResponse = {
  referenceDay: string;
  options: ReadAgeOption[];
};

export type MarkReadBeforeResponse = {
  marked: number;
  entryIds: string[];
  readAt: string;
  unreadCounts: Record<string, number>;
};

export async function fetchReadAgeOptions(
  oauthSession: OAuthSession,
  scope: GatewayMarkAllReadScope,
  timeZone: string,
  progress?: { onOptions?: (options: ReadAgeOption[]) => void; signal?: AbortSignal }
): Promise<ReadAgeOptionsResponse> {
  const params = new URLSearchParams({ kind: scope.kind, timeZone });
  if (scope.kind === "publication") {
    params.set("publicationId", scope.publicationId);
  } else if (scope.kind === "folder") {
    params.set("folderRkey", scope.folderRkey);
  }
  const response = await gatewayFetch(
    oauthSession,
    `${socialWireXrpc.getReadAgeOptions}?${params.toString()}`,
    { method: "GET", headers: { Accept: "application/x-ndjson" }, signal: progress?.signal }
  );
  if (!response.ok) {
    throw new Error(`Read age options failed (${response.status})`);
  }
  if (!response.headers.get("Content-Type")?.includes("application/x-ndjson")) {
    const result = (await response.json()) as ReadAgeOptionsResponse;
    // Keep the menu bounded while an older JSON-only server is rolling out.
    result.options = result.options.filter((option) => option.days >= 1 && option.days <= 7);
    progress?.onOptions?.(result.options);
    return result;
  }
  if (!response.body) throw new Error("Read age stream returned no body");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let latest: ReadAgeOptionsResponse | undefined;
  let completed = false;
  const consume = (line: string) => {
    if (!line.trim()) return;
    const event = JSON.parse(line);
    if (event.type === "error") throw new Error("Couldn’t load read ages. Please try again.");
    if (event.type === "done") {
      if (!latest) throw new Error("Read age stream completed without options");
      completed = true;
      return;
    }
    if (event.type !== "options" || typeof event.referenceDay !== "string" ||
        !Array.isArray(event.options) || event.options.length > 7 ||
        !event.options.every((option: ReadAgeOption) =>
          Number.isInteger(option.days) && option.days >= 1 && option.days <= 7 &&
          Number.isSafeInteger(option.count) && option.count > 0 &&
          typeof option.before === "string" && Number.isFinite(Date.parse(option.before)))) {
      throw new Error("Invalid read age stream options");
    }
    latest = { referenceDay: event.referenceDay, options: event.options };
    progress?.onOptions?.(latest.options);
  };
  try {
    while (!completed) {
      progress?.signal?.throwIfAborted();
      const { done, value } = await reader.read();
      buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
      let newline: number;
      while (!completed && (newline = buffer.indexOf("\n")) !== -1) {
        consume(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
      }
      if (done) {
        if (!completed && buffer.trim()) consume(buffer);
        break;
      }
    }
    progress?.signal?.throwIfAborted();
    if (!completed || !latest) throw new Error("Read age stream ended before completion");
    return latest;
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export async function markReadBefore(
  oauthSession: OAuthSession,
  scope: GatewayMarkAllReadScope,
  before: string
): Promise<MarkReadBeforeResponse> {
  // Keep this separate from markAllRead: old servers ignore unknown cutoff fields.
  const response = await gatewayFetch(oauthSession, socialWireXrpc.markReadBefore, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ scope, before }),
  });
  if (!response.ok) {
    throw new Error(`Mark older stories read failed (${response.status})`);
  }
  return (await response.json()) as MarkReadBeforeResponse;
}
