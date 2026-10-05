export const SIDEBAR_WIDTH_STORAGE_KEY = "the-social-wire.sidebar-width.v1";
export const SIDEBAR_WIDTH_DEFAULT_PX = 208;
export const SIDEBAR_WIDTH_MIN_PX = 200;
export const SIDEBAR_WIDTH_MAX_PX = 480;

export function clampSidebarWidth(value: number): number {
  return Number.isFinite(value)
    ? Math.min(SIDEBAR_WIDTH_MAX_PX, Math.max(SIDEBAR_WIDTH_MIN_PX, value))
    : SIDEBAR_WIDTH_DEFAULT_PX;
}
export function loadSidebarWidth(
  storage: Pick<Storage, "getItem">,
): number | null {
  try {
    const raw = storage.getItem(SIDEBAR_WIDTH_STORAGE_KEY);
    if (raw === null) return null;
    const value: unknown = JSON.parse(raw);
    return typeof value === "number" && Number.isFinite(value)
      ? clampSidebarWidth(value)
      : null;
  } catch {
    return null;
  }
}
export function saveSidebarWidth(
  storage: Pick<Storage, "setItem">,
  width: number,
): void {
  try {
    storage.setItem(
      SIDEBAR_WIDTH_STORAGE_KEY,
      String(clampSidebarWidth(width)),
    );
  } catch {
    /* Resizing still works when browser storage is unavailable. */
  }
}
