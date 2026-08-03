const PERF_FLAG = "the-social-wire.perf.subscribed";

// Local-only diagnostics. Operations consumes deidentified AppView rollups; do
// not add a browser telemetry transport or identifying dimensions here.
type SubscribedFeedPerfSample = {
  triggeredAt: number;
  renderedAt?: number;
  appendedRows?: number;
  mergeDurationMs?: number;
  triggerMarkName?: string;
};

const samples: SubscribedFeedPerfSample[] = [];
let pending: SubscribedFeedPerfSample | undefined;
let markSequence = 0;

function enabled(): boolean {
  if (typeof window === "undefined") return false;
  if (process.env.NODE_ENV === "development") return true;
  try {
    return window.localStorage.getItem(PERF_FLAG) === "1";
  } catch {
    return false;
  }
}

export function markSubscribedPaginationTriggered(): void {
  if (!enabled()) return;
  const triggerMarkName = `subscribed-feed-pagination-${markSequence += 1}-trigger`;
  performance.mark(triggerMarkName);
  pending = { triggeredAt: performance.now(), triggerMarkName };
  samples.push(pending);
}

export function markSubscribedRowsRendered(args: {
  appendedRows: number;
  mergeDurationMs: number;
}): void {
  if (!enabled() || !pending || args.appendedRows <= 0) return;
  pending.renderedAt = performance.now();
  pending.appendedRows = args.appendedRows;
  pending.mergeDurationMs = args.mergeDurationMs;
  const renderedMarkName = pending.triggerMarkName?.replace("-trigger", "-rows");
  if (pending.triggerMarkName && renderedMarkName) {
    performance.mark(renderedMarkName);
    performance.measure(
      "subscribed-feed-pagination-to-first-new-row",
      pending.triggerMarkName,
      renderedMarkName,
    );
    performance.measure(
      "subscribed-feed-page-merge",
      { start: pending.renderedAt - args.mergeDurationMs, duration: args.mergeDurationMs },
    );
  }
  console.debug("[subscribed-feed-perf]", {
    paginationToRowsMs: Math.round(pending.renderedAt - pending.triggeredAt),
    mergeDurationMs: Math.round(args.mergeDurationMs * 100) / 100,
    appendedRows: args.appendedRows,
  });
  pending = undefined;
}

export function snapshotSubscribedFeedPerf(): SubscribedFeedPerfSample[] {
  return samples.map((sample) => ({ ...sample }));
}
