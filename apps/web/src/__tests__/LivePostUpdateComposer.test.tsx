import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import * as Auth from "@/hooks/useAuth";
import * as Preview from "@/hooks/useComposeLinkPreview";
import { LivePostUpdateComposer } from "@/components/LivePosts/LivePostUpdateComposer";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
import type { LiveUpdateAttachmentsDraft } from "@/lib/livePosts/livePostMedia";

const event: LiveEvent = { $type: "app.thesocialwire.liveEvent", uri: "at://did:plc:alice/app.thesocialwire.liveEvent/event", cid: "cid", title: "Launch", tags: ["Launch"], destination: "both", createdAt: "2026-10-26T12:00:00Z", updatedAt: "2026-10-26T12:00:00Z", entries: [] };
const restores: (() => void)[] = [];
let onPublish: ReturnType<typeof mock>;
let link: ReturnType<typeof Preview.useComposeLinkPreview>;
beforeEach(() => {
  onPublish = mock(async () => {});
  link = { removedUrl: undefined, preview: undefined, loading: false, unavailable: false, needsResolution: false, remove: mock(() => {}), reset: mock(() => {}), resolve: mock(async () => undefined) };
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ getOAuthSession: () => null } as ReturnType<typeof Auth.useAuth>);
  const preview = spyOn(Preview, "useComposeLinkPreview").mockImplementation(() => link);
  const create = spyOn(URL, "createObjectURL").mockReturnValue("blob:test");
  const revoke = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  restores.push(() => auth.mockRestore(), () => preview.mockRestore(), () => create.mockRestore(), () => revoke.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function Composer({ initial = {} }: { initial?: LiveUpdateAttachmentsDraft }) {
  const [text, setText] = useState("");
  const [attachments, setAttachments] = useState(initial);
  return <LivePostUpdateComposer event={event} text={text} onTextChange={setText} attachments={attachments} onAttachmentsChange={setAttachments} pending={false} onPublish={onPublish} />;
}

test("permits media-only updates, edits alt text, and keeps media types exclusive", async () => {
  render(<Composer />);
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByLabelText("Add Images"), { target: { files: [new File(["image"], "photo.png", { type: "image/png" })] } });
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(false);
  expect((screen.getByLabelText("Add Video") as HTMLInputElement).disabled).toBe(true);
  expect((screen.getByRole("button", { name: "Add GIF" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByRole("textbox", { name: "Image 1 Alt Text" }), { target: { value: "The Launch" } });
  expect(screen.getByRole("img").getAttribute("alt")).toBe("The Launch");
  fireEvent.click(screen.getByRole("button", { name: "Publish Update" }));
  await waitFor(() => expect(onPublish).toHaveBeenCalledTimes(1));
  fireEvent.click(screen.getByRole("button", { name: "Remove Image 1" }));
  expect((screen.getByLabelText("Add Video") as HTMLInputElement).disabled).toBe(false);
});

test("rejects excess images and invalid GIF URLs before publishing", () => {
  render(<Composer />);
  fireEvent.change(screen.getByLabelText("Add Images"), { target: { files: Array.from({ length: 5 }, (_, index) => new File(["image"], `${index}.png`, { type: "image/png" })) } });
  expect(screen.getByRole("alert").textContent).toContain("Four Images");
  expect(screen.queryByRole("img")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Add GIF" }));
  fireEvent.change(screen.getByRole("textbox", { name: "GIF URL" }), { target: { value: "http://example.test/test.gif" } });
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByRole("textbox", { name: "GIF URL" }), { target: { value: "https://example.test/test.gif" } });
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(false);
  expect(onPublish).not.toHaveBeenCalled();
});

test("resolves a link once on publish and preserves text after rejection", async () => {
  let resolve: (value: undefined) => void = () => {};
  link.needsResolution = true;
  link.resolve = mock(() => new Promise<undefined>(done => { resolve = done; }));
  onPublish.mockRejectedValue(new Error("Offline"));
  render(<Composer />);
  const text = screen.getByRole("textbox", { name: "Update" });
  fireEvent.change(text, { target: { value: "https://example.test/article" } });
  fireEvent.click(screen.getByRole("button", { name: "Publish Update" }));
  expect((screen.getByRole("button", { name: "Publishing…" }) as HTMLButtonElement).disabled).toBe(true);
  expect(onPublish).not.toHaveBeenCalled();
  await act(async () => { resolve(undefined); });
  await screen.findByRole("button", { name: "Retry Publish" });
  expect((text as HTMLTextAreaElement).value).toBe("https://example.test/article");
  expect(link.resolve).toHaveBeenCalledTimes(1);
});

test("cleans up attachment object URLs and counts title and hashtags in post limits", () => {
  const view = render(<Composer initial={{ images: [{ file: new File(["image"], "photo.png", { type: "image/png" }), alt: "Photo" }] }} />);
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "x".repeat(300) } });
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByText(/exceeds Bluesky/)).toBeDefined();
  view.unmount();
  expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:test");
});

test("accepts MP4 video with alt text and rejects other video types", () => {
  render(<Composer />);
  fireEvent.change(screen.getByLabelText("Add Video"), { target: { files: [new File(["movie"], "movie.webm", { type: "video/webm" })] } });
  expect(screen.getByRole("alert").textContent).toContain("MP4");
  expect(screen.queryByLabelText("Video Attachment")).toBeNull();
  fireEvent.change(screen.getByLabelText("Add Video"), { target: { files: [new File(["movie".repeat(10)], "movie.mp4", { type: "video/mp4" })] } });
  fireEvent.change(screen.getByRole("textbox", { name: "Video Alt Text" }), { target: { value: "Launch Video" } });
  expect(screen.getByLabelText("Launch Video").tagName).toBe("VIDEO");
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(false);
  expect((screen.getByLabelText("Add Images") as HTMLInputElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Remove Video" }));
  expect(screen.queryByLabelText("Launch Video")).toBeNull();
  expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:test");
});

test("does not publish a stale event after unmount during link resolution", async () => {
  let resolve: (value: undefined) => void = () => {};
  link.needsResolution = true;
  link.resolve = mock(() => new Promise<undefined>(done => { resolve = done; }));
  const view = render(<Composer />);
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "https://example.test/article" } });
  fireEvent.click(screen.getByRole("button", { name: "Publish Update" }));
  view.unmount();
  await act(async () => { resolve(undefined); });
  expect(onPublish).not.toHaveBeenCalled();
});

test("explains oversized attachments and previews valid GIFs with alt text", () => {
  const view = render(<Composer initial={{ images: [{ file: new File([new Uint8Array(2_000_001)], "large.png", { type: "image/png" }), alt: "Large" }] }} />);
  expect(screen.getByRole("status").textContent).toContain("2 MB");
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(true);
  view.unmount();
  render(<Composer initial={{ gif: { url: "https://example.test/animation.gif", alt: "Countdown" } }} />);
  expect(screen.getByRole("img", { name: "Countdown" }).getAttribute("src")).toBe("https://example.test/animation.gif");
});
