const PERF_FLAG = "the-social-wire.perf.bootstrap";

type BootstrapPerfMark = {
  label: string;
  atMs: number;
};

const marks: BootstrapPerfMark[] = [];
let originMs: number | null = null;

function isEnabled(): boolean {
  if (typeof window === "undefined") return false;
  if (process.env.NODE_ENV === "development") return true;
  try {
    return window.localStorage.getItem(PERF_FLAG) === "1";
  } catch {
    return false;
  }
}

export function markBootstrapPerf(label: string): void {
  if (!isEnabled()) return;
  const atMs = performance.now();
  if (originMs == null) originMs = atMs;
  marks.push({ label, atMs: atMs - originMs });
  console.debug(`[bootstrap-perf] ${label} +${Math.round(atMs - originMs)}ms`);
}

export function resetBootstrapPerf(): void {
  originMs = null;
  marks.length = 0;
}

export function snapshotBootstrapPerf(): BootstrapPerfMark[] {
  return [...marks];
}
