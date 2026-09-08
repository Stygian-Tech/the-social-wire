import { ReadStateError, type OutboxState, type ReadStateStatus } from "@thesocialwire/read-state";

export const READ_STATE_RESTORING_MESSAGE = "Restoring read history. Your PDS history and pending changes remain protected. Please try again shortly.";
export const READ_STATE_SCOPE_CONFLICT_MESSAGE = "Overlapping publications have different read boundaries. Your existing history has not changed. If you want all articles in those publications marked read, use Mark All As Read, then retry. If the conflict remains, those publications need further reconciliation before migration can continue.";

export function readStateErrorMessage(error: unknown): string | undefined {
  const code = error instanceof ReadStateError ? error.code : error;
  if (code === "migration_scope_conflict") return READ_STATE_SCOPE_CONFLICT_MESSAGE;
  if (code === "projection_not_ready") return READ_STATE_RESTORING_MESSAGE;
  if (code === "reauthorize") return "Sign in again to synchronize your public read history. Pending changes remain on this device.";
  if (code === "conflict") return "Read history changed on another device. Refresh and retry; your existing history remains protected.";
  if (code === "incomplete_generation" || code === "unavailable") return "Read history sync is unavailable. Saved pending changes remain on this device and will retry.";
  return undefined;
}

export function readStateStatusMessage(status?: ReadStateStatus, outbox?: OutboxState): string | undefined {
  return readStateErrorMessage(outbox?.lastError)
    ?? (status?.projectionReady === false ? READ_STATE_RESTORING_MESSAGE : undefined);
}
