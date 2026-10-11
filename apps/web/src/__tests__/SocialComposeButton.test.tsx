import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as compose from "@/lib/blueskyComposeClient";
import { SocialComposeButton } from "@/components/Social/SocialComposeButton";

const restores: (() => void)[] = [];
let cache: QueryClient;
const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
beforeEach(() => {
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const spy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>);
  restores.push(() => spy.mockRestore());
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, MutationObserver: window.MutationObserver, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout };
  for (const [name, value] of Object.entries(values)) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function open() {
  render(<QueryClientProvider client={cache}><SocialComposeButton /></QueryClientProvider>);
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  return await screen.findByRole("textbox", { name: "Post Text" });
}

it("opens from the floating button and publishes only on explicit submission", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockResolvedValue({ uri: `at://${oauth.did}/app.bsky.feed.post/new`, cid: "cid" });
  const invalidate = spyOn(cache, "invalidateQueries");
  restores.push(() => publish.mockRestore(), () => invalidate.mockRestore());
  let dismissToast: (() => void) | undefined;
  const originalTimeout = globalThis.setTimeout;
  globalThis.setTimeout = ((callback: TimerHandler, delay?: number, ...args: unknown[]) => {
    if (delay === 3300 && typeof callback === "function") {
      dismissToast = callback as () => void;
      return originalTimeout(() => {}, 0);
    }
    return originalTimeout(callback, delay, ...args);
  }) as typeof setTimeout;
  restores.push(() => { globalThis.setTimeout = originalTimeout; });
  const field = await open();
  expect(publish).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "Hello #Bluesky" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await screen.findByRole("status");
  expect(publish).toHaveBeenCalledTimes(1);
  expect(publish.mock.calls[0][0].text).toBe("Hello #Bluesky");
  expect(publish.mock.calls[0][0].session).toBe(oauth);
  expect(invalidate).toHaveBeenCalled();
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(screen.getByRole("status").className).toContain("[animation-delay:3s]");
  expect(dismissToast).toBeDefined();
  await act(async () => dismissToast!());
  expect(screen.queryByText("Post Published")).toBeNull();
});

it("enforces grapheme limits and resets cancelled content when reopened", async () => {
  const field = await open();
  fireEvent.change(field, { target: { value: "👨‍👩‍👧‍👦".repeat(300) } });
  // This also exceeds the native byte limit even though the visible character count is valid.
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.change(field, { target: { value: "a".repeat(301) } });
  expect(screen.getByText("301/300")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  expect((await screen.findByRole("textbox", { name: "Post Text" }) as HTMLTextAreaElement).value).toBe("");
});

it("preserves content on failure and allows retry", async () => {
  const publish = spyOn(compose, "createBlueskyPost").mockRejectedValue(new Error("Post failed"));
  restores.push(() => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "Keep this draft" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Your post could not be published. Please try again."));
  expect((field as HTMLTextAreaElement).value).toBe("Keep this draft");
  expect(screen.getByRole("button", { name: "Post" }).hasAttribute("disabled")).toBe(false);
});

it("prevents duplicate submission and closing while a post is pending", async () => {
  let resolve!: (value: { uri: string; cid: string }) => void;
  const publish = spyOn(compose, "createBlueskyPost").mockReturnValue(new Promise(complete => { resolve = complete; }));
  restores.push(() => publish.mockRestore());
  const field = await open();
  fireEvent.change(field, { target: { value: "Once" } });
  fireEvent.click(screen.getByRole("button", { name: "Post" }));
  expect(screen.getByRole("button", { name: "Publishing…" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Cancel" }).hasAttribute("disabled")).toBe(true);
  expect(publish).toHaveBeenCalledTimes(1);
  await act(async () => resolve({ uri: "at://did:plc:viewer/app.bsky.feed.post/new", cid: "cid" }));
});
