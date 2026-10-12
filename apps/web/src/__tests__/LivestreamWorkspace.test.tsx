import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as Auth from "@/hooks/useAuth";
import * as Live from "@/hooks/useLivestream";
import * as Mobile from "@/hooks/use-mobile";
import * as Chat from "@/components/Livestream/LivestreamChat";
import { SidebarProvider } from "@/components/ui/sidebar";
import { LivestreamWorkspace } from "@/components/Livestream/LivestreamWorkspace";
import type { Livestream } from "@/lib/livestream/livestreamTypes";
const stream: Livestream = { uri: "at://did:plc:alice/place.stream.livestream/3mf6w2zabcd22", cid: "cid", record: { $type: "place.stream.livestream", title: "Live", createdAt: "2026-10-11T12:00:00Z", tags: [] } };
const restores: (() => void)[] = [];
let state: ReturnType<typeof Live.useLivestream>;
let did: string;
beforeEach(() => {
  did = "did:plc:alice";
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false); restores.push(() => mobile.mockRestore());
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did } }) as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const chat = spyOn(Chat, "LivestreamChat").mockImplementation(() => <div>Chat Workspace</div>); restores.push(() => chat.mockRestore());
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name); Object.defineProperty(globalThis, name, { configurable: true, value }); restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  state = { did, streams: [], loading: false, ingests: [{ type: "rtmps", url: "rtmps://rtmp.stream.place/live" }], snapshot: { messages: [], connected: false }, pending: false, error: undefined,
    generateKey: mock(async () => ({ secret: "test-memory-only-secret", signingKey: "did:key:test", uri: "at://did:plc:alice/place.stream.key/key" })), save: mock(async () => stream), end: mock(async () => ({ ...stream, record: { ...stream.record, endedAt: "2026-10-11T13:00:00Z" } })), send: mock(async () => {}), uploadThumbnail: mock(async () => ({ $type: "blob", ref: { $link: "cid" }, mimeType: "image/png", size: 1 })), refresh: mock(async () => undefined) } as unknown as ReturnType<typeof Live.useLivestream>;
  const live = spyOn(Live, "useLivestream").mockImplementation(() => state); restores.push(() => live.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
async function mount() { let view: ReturnType<typeof render>; await act(async () => { view = render(<SidebarProvider><LivestreamWorkspace /></SidebarProvider>); }); return view!; }
test("announces and ends only after explicit confirmation without claiming encoder control", async () => {
  await mount(); fireEvent.change(screen.getByRole("textbox", { name: "Livestream Title" }), { target: { value: "Live" } });
  fireEvent.click(screen.getByRole("button", { name: "Start Livestream" })); expect(state.save).not.toHaveBeenCalled(); expect(screen.getByText(/Does Not Start Your Encoder/)).toBeDefined();
  fireEvent.click(screen.getByRole("button", { name: "Confirm Start Livestream" })); await waitFor(() => expect(state.save).toHaveBeenCalledTimes(1));
  fireEvent.click(screen.getByRole("button", { name: "End Livestream" })); expect(state.end).not.toHaveBeenCalled(); expect(screen.getByText(/Stop Broadcasting In Your Encoder Separately/)).toBeDefined();
  fireEvent.click(screen.getByRole("button", { name: "Confirm End Livestream" })); await waitFor(() => expect(state.end).toHaveBeenCalledTimes(1));
});
test("key stays masked and clears on account and node changes", async () => {
  const view = await mount(); fireEvent.click(screen.getByRole("button", { name: "Generate Stream Key" }));
  const key = await screen.findByLabelText("Private Stream Key"); expect(key.getAttribute("type")).toBe("password");
  fireEvent.click(screen.getByRole("button", { name: "Show Key" })); expect(key.getAttribute("type")).toBe("text");
  did = "did:plc:bob"; await act(async () => { view.rerender(<SidebarProvider><LivestreamWorkspace /></SidebarProvider>); }); expect(screen.queryByLabelText("Private Stream Key")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Generate Stream Key" })); await screen.findByLabelText("Private Stream Key");
  fireEvent.change(screen.getByLabelText("Custom Streamplace Node"), { target: { value: "https://custom.example.com" } }); fireEvent.click(screen.getByRole("button", { name: "Connect Node" })); expect(screen.queryByLabelText("Private Stream Key")).toBeNull();
});
test("unavailable status is not invented as zero, unsafe custom nodes fail visibly", async () => {
  await mount(); expect(screen.getByText("Concurrent Viewers: Unavailable")).toBeDefined(); expect(screen.getByText("Total Playback Sessions: Unavailable")).toBeDefined();
  fireEvent.change(screen.getByLabelText("Custom Streamplace Node"), { target: { value: "http://localhost:8080" } }); fireEvent.click(screen.getByRole("button", { name: "Connect Node" })); expect(screen.getByRole("alert").textContent).toContain("Public HTTPS");
});


test("keeps the shared livestream top bar outside its scrolling workspace", async () => {
  await mount();
  const header = screen.getByRole("heading", { name: "Livestream" }).closest("header")!;
  expect(header.classList.contains("floating-glass")).toBe(true);
  expect(header.parentElement!.classList.contains("overflow-hidden")).toBe(true);
  expect(header.nextElementSibling!.classList.contains("overflow-y-auto")).toBe(true);
  expect(header.nextElementSibling!.classList.contains("min-h-0")).toBe(true);
});
