import { afterEach, beforeAll, expect, it, mock } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { PodcastLibrarySidebar } from "@/components/Podcasts/PodcastLibrarySidebar";
import { PodcastUnsubscribeDialog } from "@/components/Podcasts/PodcastUnsubscribeDialog";
import type { PodcastShow } from "@/lib/podcasts/client";

const show: PodcastShow = { id: "owned", title: "My Podcast", sourceKind: "rss" };
beforeAll(() => {
  globalThis.getComputedStyle ??= window.getComputedStyle.bind(window);
  globalThis.requestAnimationFrame ??= (callback) => setTimeout(() => callback(performance.now()), 0) as unknown as number;
  globalThis.cancelAnimationFrame ??= (id) => clearTimeout(id);
});
afterEach(cleanup);
function Library({ onConfirm }: { onConfirm: (show: PodcastShow) => Promise<void> }) {
  const [selected, setSelected] = useState<PodcastShow | null>(null);
  return <>
    <PodcastLibrarySidebar feed="recent" showId={null} shows={[show]} subscriptions={[show.id]} downloadCount={0} queueCount={0} onSelect={() => {}} onUnsubscribe={setSelected} />
    <PodcastUnsubscribeDialog key={selected?.id ?? "closed"} show={selected} onClose={() => setSelected(null)} onConfirm={onConfirm} />
  </>;
}
async function openConfirmation() {
  fireEvent.contextMenu(screen.getByRole("button", { name: show.title }), { clientX: 20, clientY: 20, button: 2 });
  const item = await screen.findByRole("menuitem", { name: "Unsubscribe" });
  expect(item.getAttribute("data-variant")).toBe("destructive");
  fireEvent.click(item);
  await screen.findByRole("dialog");
}
it("offers destructive unsubscribe on right click and cancel never mutates subscriptions", async () => {
  const confirm = mock(async () => {});
  render(<Library onConfirm={confirm} />);
  await openConfirmation();
  expect(screen.getByText(/Unsubscribe from My Podcast/)).toBeTruthy();
  expect(confirm).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(confirm).not.toHaveBeenCalled();
});
it("confirms once, blocks duplicate submission and closes only after success", async () => {
  let finish!: () => void;
  const confirm = mock(() => new Promise<void>(resolve => { finish = resolve; }));
  render(<Library onConfirm={confirm} />);
  await openConfirmation();
  fireEvent.click(screen.getByRole("button", { name: "Unsubscribe" }));
  expect((screen.getByRole("button", { name: "Unsubscribing…" }) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByRole("button", { name: "Cancel" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Unsubscribing…" }));
  expect(confirm).toHaveBeenCalledTimes(1);
  expect(confirm).toHaveBeenCalledWith(show);
  await act(async () => finish());
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});
it("keeps confirmation open on failure and allows retry", async () => {
  const confirm = mock(async () => {}).mockRejectedValueOnce(new Error("Subscription Could Not Be Removed"));
  render(<Library onConfirm={confirm} />);
  await openConfirmation();
  fireEvent.click(screen.getByRole("button", { name: "Unsubscribe" }));
  expect((await screen.findByRole("alert")).textContent).toBe("Subscription Could Not Be Removed");
  expect(screen.getByRole("dialog")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Unsubscribe" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(confirm).toHaveBeenCalledTimes(2);
});
