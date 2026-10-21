import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, render, waitFor } from "@testing-library/react";
import { SocialComposerGifPreview } from "@/components/Social/SocialComposerGifPreview";
import type { ComposerGif } from "@/lib/composerMedia";
import { describeDraftAttachment } from "@/lib/socialDraftAttachmentClient";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
it("uses authenticated recovered Blob URLs for every preview source and revokes them on unmount", async () => {
  const asset = { id: "id", title: "GIF", description: "", attribution: "KLIPY", url: "https://static.klipy.com/ii/a/a.gif", poster: "https://static.klipy.com/ii/a/p.jpg", mp4: "https://static.klipy.com/ii/a/a.mp4", webm: "https://static.klipy.com/ii/a/a.webm", width: 10, height: 20 };
  const files: NonNullable<ComposerGif["privateFiles"]>["files"] = {};
  for (const rendition of ["gif", "poster", "mp4", "webm"] as const) {
    const blob = new Blob([rendition], { type: rendition === "gif" ? "image/gif" : rendition === "poster" ? "image/jpeg" : `video/${rendition}` });
    files[rendition] = { blob, asset: { ...await describeDraftAttachment(blob, rendition, undefined, rendition === "mp4" || rendition === "webm" ? "video" : rendition), state: "ready" } };
  }
  const create = spyOn(URL, "createObjectURL").mockImplementation(blob => `blob:private-${(blob as Blob).type}`);
  const revoke = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  restores.push(() => create.mockRestore(), () => revoke.mockRestore());
  const rendered = render(<SocialComposerGifPreview media={{ kind: "gif", asset, alt: "Description", privateFiles: { ownerDid: "did:plc:owner", identity: "identity", referenceKey: "key", files } }} />);
  await waitFor(() => expect(rendered.container.querySelector("video")?.getAttribute("poster")).toBe("blob:private-image/jpeg"));
  expect(Array.from(rendered.container.querySelectorAll("source")).map(source => source.src)).toEqual(["blob:private-video/webm", "blob:private-video/mp4"]);
  expect(rendered.container.innerHTML).not.toContain("static.klipy.com");
  expect(create).toHaveBeenCalledTimes(4); rendered.unmount(); expect(revoke).toHaveBeenCalledTimes(4);
});
it("does not load a public preview when restored GIF files are unavailable", () => {
  const rendered = render(<SocialComposerGifPreview media={{ kind: "gif", unavailable: true, alt: "", asset: { id: "uri-id", title: "GIF", description: "", attribution: "KLIPY", url: "https://static.klipy.com/ii/a/a.gif", poster: "https://static.klipy.com/ii/a/p.jpg", width: 10, height: 20 } }} />);
  expect(rendered.getByRole("status").textContent).toContain("Reselect"); expect(rendered.container.querySelector("video, img, source")).toBeNull();
});
