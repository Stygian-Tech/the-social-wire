import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import type React from "react";

import type { EntryDetail, EntryListItem } from "@/lib/atprotoClient";
import type { MergedLatrSave } from "@/lib/pdsClient";

mock.module("@/components/EntryDetail/ArticleSocialToolbar", () => ({
  ArticleSocialToolbar: ({
    entry,
    variant,
  }: {
    entry: EntryDetail | null;
    variant?: string;
  }) =>
    entry && variant === "menu" ? (
      <button type="button" aria-label="Article Actions">
        {entry.title}
      </button>
    ) : null,
}));

mock.module("@/components/ui/button", () => ({
  Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement> & {
    variant?: string;
    size?: string;
  }) => {
    const { variant, size, ...buttonProps } = props;
    void variant;
    void size;
    return <button {...buttonProps}>{children}</button>;
  },
}));

afterEach(cleanup);

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

    render(<EntryCardActionMenu entry={entry} />);

    expect(
      screen.getByRole("button", { name: "Article Actions" }).textContent,
    ).toBe(entry.title);
  });

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
    const onArchive = mock(() => undefined);
    const onUnarchive = mock(() => undefined);
    const onDelete = mock(() => undefined);

    const { rerender } = render(
      <SavedLinkCardActions
        row={row}
        isArchivedView={false}
        disabled={false}
        onOpen={onOpen}
        onArchive={onArchive}
        onUnarchive={onUnarchive}
        onDelete={onDelete}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open Saved Article" }));
    fireEvent.click(
      screen.getByRole("button", { name: "Archive Saved Article" }),
    );
    fireEvent.click(
      screen.getByRole("button", {
        name: "Remove Saved Article From Library",
      }),
    );

    expect(onOpen).toHaveBeenCalledWith(row);
    expect(onArchive).toHaveBeenCalledWith(row);
    expect(onDelete).toHaveBeenCalledWith(row);

    rerender(
      <SavedLinkCardActions
        row={row}
        isArchivedView
        disabled={false}
        onOpen={onOpen}
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
