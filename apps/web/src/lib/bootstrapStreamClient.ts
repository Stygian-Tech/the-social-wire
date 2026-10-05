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

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      buffer = consumeBufferedNdjsonLines(buffer, handlers);
    }
    if (buffer.trim()) {
      consumeLine(buffer.trim(), handlers);
    }
  } catch (error) {
    if (signal?.aborted) return;
    handlers.onError?.(error instanceof Error ? error : new Error(String(error)));
    throw error;
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
