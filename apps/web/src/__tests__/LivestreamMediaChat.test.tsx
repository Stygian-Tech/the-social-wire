import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type Hls from "hls.js";
import * as Playback from "@/lib/socialVideoPlayback";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import { LivestreamPreview } from "@/components/Livestream/LivestreamPreview";
import { LivestreamChat } from "@/components/Livestream/LivestreamChat";
import type { StreamChatMessage } from "@/lib/livestream/livestreamTypes";
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
test("preview lazy player attaches public HLS, reports failures and destroys engine", async () => {
  const load = mock((url: string) => { void url; }), attach = mock((video: HTMLMediaElement) => { void video; }), destroy = mock(() => {});
  let fatal!: (_event: string, value: { fatal: boolean }) => void;
  class Engine {
    static isSupported() { return true; } static Events = { ERROR: "error" };
    on(_event: string, callback: typeof fatal) { fatal = callback; } loadSource = load; attachMedia = attach; destroy = destroy;
  }
  const spy = spyOn(Playback, "loadSocialVideoHls").mockResolvedValue(Engine as unknown as typeof Hls); restores.push(() => spy.mockRestore());
  const view = render(<LivestreamPreview node="https://stream.place" did="did:plc:alice" />);
  await waitFor(() => expect(attach).toHaveBeenCalledTimes(1)); expect(load.mock.calls[0]![0]).toBe("https://stream.place/xrpc/place.stream.playback.getLivePlaylist?streamer=did%3Aplc%3Aalice");
  const video = screen.getByLabelText("Livestream Preview"); expect(video.getAttribute("poster")).toContain("/api/playback/did%3Aplc%3Aalice/stream.jpg");
  act(() => fatal("error", { fatal: true })); expect(screen.getByRole("status").textContent).toContain("No Live Playback"); view.unmount(); expect(destroy).toHaveBeenCalledTimes(1);
});
test("preview visibly handles engine import failure", async () => {
  const spy = spyOn(Playback, "loadSocialVideoHls").mockRejectedValue(new Error("Load Failed")); restores.push(() => spy.mockRestore());
  render(<LivestreamPreview node="https://stream.place" did="did:plc:alice" />); expect((await screen.findByRole("status")).textContent).toContain("No Live Playback");
});
test("chat respects profile moderation and catalog failure before showing messages or sending", () => {
  const moderation = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
  let failed = false;
  const spy = spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => ({ data: { moderation }, isError: failed }) as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>); restores.push(() => spy.mockRestore());
  const message: StreamChatMessage = { uri: "at://did:plc:author/place.stream.chat.message/msg", cid: "cid", author: { did: "did:plc:author", handle: "author.test" }, record: { $type: "place.stream.chat.message", text: "Public Message", streamer: "did:plc:viewer", createdAt: "2026-10-11T12:00:00Z" } };
  const send = mock(() => {}), props = { messages: [message, { ...message, uri: `${message.uri}blocked`, author: { ...message.author, viewer: { muted: true } }, record: { ...message.record, text: "Muted Message" } }], text: "Reply", onChange: () => {}, onSend: send, pending: false, connected: true };
  const view = render(<LivestreamChat {...props} />); expect(screen.getByText("Public Message")).toBeDefined(); expect(screen.queryByText("Muted Message")).toBeNull(); expect(send).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Send Message" })); expect(send).toHaveBeenCalledTimes(1);
  failed = true; view.rerender(<LivestreamChat {...props} />); expect(screen.queryByText("Public Message")).toBeNull(); expect((screen.getByRole("button", { name: "Send Message" }) as HTMLButtonElement).disabled).toBe(true); expect(screen.getByRole("status").textContent).toContain("Withheld");
});


test("keeps a long chat in its own scroll region and preserves composer access when the rail is short", () => {
  const moderation = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
  const spy = spyOn(Catalog, "useBlueskySocialCatalog").mockReturnValue({ data: { moderation }, isError: false } as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>);
  restores.push(() => spy.mockRestore());
  const messages: StreamChatMessage[] = Array.from({ length: 60 }, (_, index) => ({ uri: `at://did:plc:author/place.stream.chat.message/${index}`, cid: "cid", author: { did: "did:plc:author", handle: "author.test" }, record: { $type: "place.stream.chat.message", text: `Public Message ${index}`, streamer: "did:plc:viewer", createdAt: "2026-10-11T12:00:00Z" } }));
  const onChange = mock(() => {}), onSend = mock(() => {});
  render(<div style={{ height: 240 }}><LivestreamChat messages={messages} text="Reply" onChange={onChange} onSend={onSend} pending={false} connected /></div>);
  const rail = screen.getByRole("complementary", { name: "Stream Chat" });
  const log = screen.getByRole("log", { name: "Stream Chat Messages" });
  expect(log.contains(screen.getByText("Public Message 59"))).toBe(true);
  expect(log.classList.contains("overflow-y-auto")).toBe(true);
  expect(log.classList.contains("lg:flex-1")).toBe(true);
  expect(log.classList.contains("lg:max-h-none")).toBe(true);
  expect(rail.classList.contains("lg:min-h-0")).toBe(true);
  expect(rail.classList.contains("lg:overflow-y-auto")).toBe(true);
  const composer = screen.getByRole("textbox", { name: "Stream Chat Message" });
  expect(log.contains(composer)).toBe(false);
  expect(composer.parentElement!.classList.contains("shrink-0")).toBe(true);
  fireEvent.change(composer, { target: { value: "New Reply" } });
  expect(onChange).toHaveBeenCalledWith("New Reply");
  fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
  expect(onSend).toHaveBeenCalledTimes(1);
});
