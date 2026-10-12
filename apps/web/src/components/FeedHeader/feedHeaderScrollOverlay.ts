import { attachFloatingGlassScrollOverlay } from "@/components/shared/floatingGlassScrollOverlay";

/** Shared glass presentation for direct feeds and nested reader shells. */
export function attachFeedHeaderScrollOverlay(header: HTMLElement) {
  return attachFloatingGlassScrollOverlay(header, "top");
}
