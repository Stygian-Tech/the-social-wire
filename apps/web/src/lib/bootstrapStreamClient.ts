import type { OAuthSession } from "@atproto/oauth-client-browser";

import {
  parseBootstrapStreamEvent,
  type BootstrapStreamEvent,
  type ParsedBootstrapStreamEvent,
} from "@/lib/bootstrapStreamModels";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export type BootstrapStreamHandlers = {
  onEvent: (event: ParsedBootstrapStreamEvent) => void;
  onError?: (error: Error) => void;
};

export async function consumeBootstrapStream(args: {
  oauthSession: OAuthSession;
  signal?: AbortSignal;
  handlers: BootstrapStreamHandlers;
}): Promise<void> {
  const { oauthSession, signal, handlers } = args;
  const res = await gatewayFetch(oauthSession, "/v1/appview/bootstrap-stream?includeLists=true", {
    method: "GET",
    headers: { Accept: "application/x-ndjson" },
    signal,
  });

  if (!res.ok) {
    throw new Error(`Bootstrap stream failed (${res.status})`);
  }
  if (!res.body) {
    throw new Error("Bootstrap stream returned no body");
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let complete = false;
  const streamHandlers: BootstrapStreamHandlers = {
    ...handlers,
    onEvent: event => {
      if (complete) return;
      handlers.onEvent(event);
      if (event.kind === "done") complete = true;
    },
  };
  // An open HTTP body must not keep Refresh pending after protocol completion,
  // and abort must also wake a reader stalled between NDJSON chunks.
  const cancelReader = () => { void reader.cancel().catch(() => undefined); };
  signal?.addEventListener("abort", cancelReader, { once: true });

  try {
    signal?.throwIfAborted();
    while (true) {
      const { done, value } = await reader.read();
      signal?.throwIfAborted();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      buffer = consumeBufferedNdjsonLines(buffer, streamHandlers);
      if (complete) break;
    }
    if (!complete && buffer.trim()) {
      consumeLine(buffer.trim(), streamHandlers);
    }
  } catch (error) {
    if (signal?.aborted) throw signal.reason;
    handlers.onError?.(error instanceof Error ? error : new Error(String(error)));
    throw error;
  } finally {
    signal?.removeEventListener("abort", cancelReader);
    cancelReader();
    reader.releaseLock();
  }
}

function consumeBufferedNdjsonLines(
  buffer: string,
  handlers: BootstrapStreamHandlers
): string {
  let rest = buffer;
  while (true) {
    const newlineIndex = rest.indexOf("\n");
    if (newlineIndex === -1) break;
    const line = rest.slice(0, newlineIndex).trim();
    rest = rest.slice(newlineIndex + 1);
    if (line) consumeLine(line, handlers);
  }
  return rest;
}

function consumeLine(line: string, handlers: BootstrapStreamHandlers): void {
  let raw: BootstrapStreamEvent;
  try {
    raw = JSON.parse(line) as BootstrapStreamEvent;
  } catch (error) {
    handlers.onError?.(
      error instanceof Error ? error : new Error("Invalid bootstrap stream JSON line")
    );
    return;
  }
  const parsed = parseBootstrapStreamEvent(raw);
  if (parsed) handlers.onEvent(parsed);
}

export function parseNdjsonLinesForTest(input: string): ParsedBootstrapStreamEvent[] {
  const events: ParsedBootstrapStreamEvent[] = [];
  consumeBufferedNdjsonLines(`${input.trim()}\n`, {
    onEvent: (event) => events.push(event),
  });
  return events;
}
