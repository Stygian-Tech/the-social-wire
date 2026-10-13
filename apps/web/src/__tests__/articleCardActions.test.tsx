import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import userEvent from "@testing-library/user-event";
import * as Auth from "@/hooks/useAuth";
import * as Toolbar from "@/components/EntryDetail/ArticleSocialToolbar";
import { DropdownMenuContent, DropdownMenuItem } from "@/components/ui/dropdown-menu";

import type { EntryDetail, EntryListItem } from "@/lib/atprotoClient";
import type { MergedLatrSave } from "@/lib/pdsClient";

const styleDescriptor = Object.getOwnPropertyDescriptor(globalThis, "getComputedStyle");
const frameDescriptors = [globalThis, window].flatMap(target => ["requestAnimationFrame", "cancelAnimationFrame"].map(name => ({ target, name, descriptor: Object.getOwnPropertyDescriptor(target, name) })));
beforeAll(() => {
  Object.defineProperty(globalThis, "getComputedStyle", { configurable: true, value: window.getComputedStyle.bind(window) });
  for (const target of [globalThis, window]) {
    Object.defineProperty(target, "requestAnimationFrame", { configurable: true, value: (callback: FrameRequestCallback) => window.setTimeout(() => callback(performance.now()), 0) });
    Object.defineProperty(target, "cancelAnimationFrame", { configurable: true, value: (id: number) => window.clearTimeout(id) });
  }
});
afterAll(() => {
  if (styleDescriptor) Object.defineProperty(globalThis, "getComputedStyle", styleDescriptor);
  else Reflect.deleteProperty(globalThis, "getComputedStyle");
  for (const { target, name, descriptor } of frameDescriptors) {
    if (descriptor) Object.defineProperty(target, name, descriptor);
    else Reflect.deleteProperty(target, name);
  }
});

let viewer = "did:plc:viewer";
let reloadSeq = 0;
const action = mock((entryId?: string) => { void entryId; });
let controller: ReturnType<typeof spyOn>;
const restores: (() => void)[] = [];
function TestController({ entry, showWireFeedback, menuContentOnly }: { entry: EntryDetail | null; showWireFeedback?: boolean; menuContentOnly?: boolean }) {
  const [dialog, setDialog] = useState(false);
  return <>
    <DropdownMenuContent align="end">
      <DropdownMenuItem onClick={() => action(entry?.entryId)}>Save {entry?.title}</DropdownMenuItem>
      <DropdownMenuItem onClick={() => setDialog(true)}>Post</DropdownMenuItem>
      {showWireFeedback ? <DropdownMenuItem>Wire Feedback</DropdownMenuItem> : null}
    </DropdownMenuContent>
    {dialog ? <div role="dialog"><span>Post {entry?.title}</span><button onClick={() => setDialog(false)}>Close Composer</button></div> : null}
    {!menuContentOnly ? <span>Unexpected Nested Trigger</span> : null}
  </>;
}
beforeEach(() => {
  viewer = "did:plc:viewer";
  reloadSeq = 0;
  action.mockClear();
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, oauthSessionReloadSeq: reloadSeq }) as ReturnType<typeof Auth.useAuth>);
  controller = spyOn(Toolbar, "ArticleSocialToolbar").mockImplementation(TestController);
  restores.push(() => auth.mockRestore(), () => controller.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

describe("article card actions", () => {
  it("reuses the article reader action menu for feed cards", async () => {
    const { EntryCardActionMenu } = await import(
      "@/components/EntryList/EntryCardActionMenu"
    );
    const entry: EntryListItem = {
      entryId: "at://did:plc:author/site.standard.document/article",
      title: "Reader Actions on a Card",
      summary: "A card summary",
      publishedAt: "2026-07-31T00:00:00.000Z",
      originalUrl: "https://example.com/article",
    };

    const rowClick = mock(() => undefined);
    render(<div onClick={rowClick}><EntryCardActionMenu entry={entry} /></div>);

    expect(controller).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Article Actions" }));
    await screen.findByRole("menuitem", { name: `Save ${entry.title}` });
    expect(controller).toHaveBeenCalled();
    expect(screen.queryByText("Unexpected Nested Trigger")).toBeNull();
    fireEvent.click(screen.getByRole("menuitem", { name: `Save ${entry.title}` }));
    expect(action).toHaveBeenCalledWith(entry.entryId);
    expect(rowClick).not.toHaveBeenCalled();
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole("button", { name: "Article Actions" })));
  });

  it("enables article-quality feedback only for Wire cards", async () => {
    const { EntryCardActionMenu } = await import(
      "@/components/EntryList/EntryCardActionMenu"
    );
    const entry: EntryListItem = {
      entryId: "at://did:plc:author/app.bsky.feed.post/article",
      title: "Wire Article",
      publishedAt: "2026-08-22T00:00:00.000Z",
      originalUrl: "https://example.com/article",
    };
    const { rerender } = render(<EntryCardActionMenu entry={entry} />);
    fireEvent.click(screen.getByRole("button", { name: "Article Actions" }));
    await screen.findByRole("menuitem", { name: `Save ${entry.title}` });
    expect(screen.queryByRole("menuitem", { name: "Wire Feedback" })).toBeNull();
    rerender(<EntryCardActionMenu entry={entry} showWireFeedback />);
    expect(screen.getByRole("menuitem", { name: "Wire Feedback" })).toBeTruthy();
  });

  it("opens on the first keyboard activation without navigating the card", async () => {
    const { EntryCardActionMenu } = await import("@/components/EntryList/EntryCardActionMenu");
    const click = mock(() => undefined);
    const entry: EntryListItem = { entryId: "keyboard", title: "Keyboard Article", publishedAt: "2026-07-31T00:00:00.000Z" };
    render(<div onClick={click} onKeyDown={click}><EntryCardActionMenu entry={entry} /></div>);
    const trigger = screen.getByRole("button", { name: "Article Actions" });
    trigger.focus();
    await userEvent.keyboard("{Enter}");
    const first = await screen.findByRole("menuitem", { name: "Save Keyboard Article" });
    await waitFor(() => expect(document.activeElement).toBe(first));
    await userEvent.keyboard("{Enter}");
    expect(action).toHaveBeenCalledWith("keyboard");
    expect(click).not.toHaveBeenCalled();
  });

  for (const replacement of ["account", "article", "session reload"] as const) {
    it(`retains composer state after closing the menu and resets on ${replacement} replacement`, async () => {
      const { EntryCardActionMenu } = await import("@/components/EntryList/EntryCardActionMenu");
      let entry: EntryListItem = { entryId: "original", title: "Original Article", publishedAt: "2026-07-31T00:00:00.000Z" };
      const { rerender } = render(<EntryCardActionMenu entry={entry} />);
      fireEvent.click(screen.getByRole("button", { name: "Article Actions" }));
      fireEvent.click(await screen.findByRole("menuitem", { name: "Post" }));
      expect(screen.getByRole("dialog").textContent).toContain("Original Article");
      if (replacement === "account") viewer = "did:plc:successor";
      else if (replacement === "session reload") reloadSeq++;
      else entry = { ...entry, entryId: "replacement", title: "Replacement Article" };
      const before = controller.mock.calls.length;
      rerender(<EntryCardActionMenu entry={entry} />);
      expect(screen.queryByRole("dialog")).toBeNull();
      expect(controller.mock.calls.length).toBe(before);
      fireEvent.click(screen.getByRole("button", { name: "Article Actions" }));
      await screen.findByRole("menuitem", { name: `Save ${entry.title}` });
      expect(screen.queryByRole("dialog")).toBeNull();
    });
  }

  it("shows the L@tr-style open, archive, and remove button row", async () => {
    const { SavedLinkCardActions } = await import(
      "@/components/SavedLinks/SavedLinkCardActions"
    );
    const row: MergedLatrSave = {
      kind: "external",
      normalizedUrl: "https://example.com/article",
      url: "https://example.com/article",
      savedAt: "2026-07-31T00:00:00.000Z",
      externalRkey: "external",
      itemRkey: "item",
      externalUri: "at://did:plc:viewer/link.latr.saved.external/external",
      itemUri: "at://did:plc:viewer/link.latr.saved.item/item",
      subjectUri: "at://did:plc:viewer/link.latr.saved.external/external",
      title: "Saved Article",
    };
    const onOpen = mock(() => undefined);
    const onEditTags = mock(() => undefined);
    const onArchive = mock(() => undefined);
    const onUnarchive = mock(() => undefined);
    const onDelete = mock(() => undefined);

    const { rerender } = render(
      <SavedLinkCardActions
        row={row}
        isArchivedView={false}
        disabled={false}
        onOpen={onOpen}
        onEditTags={onEditTags}
        onArchive={onArchive}
        onUnarchive={onUnarchive}
        onDelete={onDelete}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open Saved Article" }));
    fireEvent.click(screen.getByRole("button", { name: "Edit Tags for Saved Article" }));
    fireEvent.click(
      screen.getByRole("button", { name: "Archive Saved Article" }),
    );
    fireEvent.click(
      screen.getByRole("button", {
        name: "Remove Saved Article From Library",
      }),
    );

    expect(onOpen).toHaveBeenCalledWith(row);
    expect(onEditTags).toHaveBeenCalledWith(row);
    expect(onArchive).toHaveBeenCalledWith(row);
    expect(onDelete).toHaveBeenCalledWith(row);

    rerender(
      <SavedLinkCardActions
        row={row}
        isArchivedView
        disabled={false}
        onOpen={onOpen}
        onEditTags={onEditTags}
        onArchive={onArchive}
        onUnarchive={onUnarchive}
        onDelete={onDelete}
      />,
    );
    fireEvent.click(
      screen.getByRole("button", { name: "Unarchive Saved Article" }),
    );
    expect(onUnarchive).toHaveBeenCalledWith(row);
  });
});
