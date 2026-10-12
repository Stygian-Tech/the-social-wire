import type { Livestream, StreamChatMessage, StreamSnapshot } from "./livestreamTypes";
/** Validate the public websocket before exposing any data to the workspace. */
export function reduceStreamSnapshot(snapshot: StreamSnapshot, payload: unknown, did: string): StreamSnapshot {
  let next = snapshot;
  for (const item of Array.isArray(payload) ? payload : [payload]) {
    if (!item || typeof item !== "object") continue;
    const value = item as Record<string, unknown>;
    if (value.$type === "place.stream.livestream#viewerCount") {
      if (Number.isSafeInteger(value.count) && (value.count as number) >= 0) next = { ...next, viewers: value.count as number, totalSessions: Number.isSafeInteger(value.total) && (value.total as number) >= 0 ? value.total as number : undefined };
    } else if (value.$type === "place.stream.livestream#livestreamView") {
      const stream = value as unknown as Livestream;
      if (typeof stream.uri === "string" && stream.uri.startsWith(`at://${did}/place.stream.livestream/`) && typeof stream.cid === "string" && stream.record?.$type === "place.stream.livestream" && typeof stream.record.title === "string") next = { ...next, ...(next.stream && next.stream.uri !== stream.uri ? { messages: [], viewers: undefined, totalSessions: undefined } : {}), stream };
    } else if (value.$type === "place.stream.chat.defs#messageView") {
      const message = value as unknown as StreamChatMessage;
      if (typeof message.author?.did !== "string" || !/^did:[^\s/?#]+$/.test(message.author.did) || (message.author.displayName !== undefined && typeof message.author.displayName !== "string") || !Number.isFinite(Date.parse(message.record?.createdAt)) || typeof message.uri !== "string" || !message.uri.startsWith(`at://${message.author?.did}/place.stream.chat.message/`) || typeof message.author?.handle !== "string" || message.record?.$type !== "place.stream.chat.message" || message.record.streamer !== did || typeof message.record.text !== "string" || message.record.text.length > 3000) continue;
      next = { ...next, messages: [...next.messages.filter(old => old.uri !== message.uri), message].sort((a, b) => Date.parse(a.record.createdAt) - Date.parse(b.record.createdAt)).slice(-200) };
    }
  }
  return next;
}
