import { afterEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { EntryDetail } from "@/lib/atprotoClient";
import * as Toolbar from "@/components/EntryDetail/ArticleSocialToolbar";

const restores: (() => void)[] = [];
afterEach(() => {
  cleanup();
  restores.splice(0).reverse().forEach(restore => restore());
});

const entry: EntryDetail = {
  entryId: "at://did:plc:author/site.standard.document/article",
  title: "A Better Article Header",
  publishedAt: "2026-07-29T00:00:00.000Z",
  contentHtml: "<p>Article body</p>",
};

it("shows the selected title and a single action menu in the reader header", async () => {
  const toolbar = spyOn(Toolbar, "ArticleSocialToolbar").mockImplementation(({ entry, variant }) =>
    entry && variant === "menu" ? <button type="button" aria-label="Article Actions" /> : null,
  );
  restores.push(() => toolbar.mockRestore());
  const onBack = mock(() => undefined);
  const { ReaderPaneHeader } = await import(
    "@/components/EntryDetail/ReaderPaneHeader"
  );

  render(
    <ReaderPaneHeader
      entry={entry}
      fallbackTitle="Articles"
      onBack={onBack}
    />
  );

  expect(screen.getByText(entry.title)).toBeDefined();
  expect(screen.queryByText("Articles")).toBeNull();
  expect(screen.getAllByRole("button")).toHaveLength(2);
  expect(
    screen.getByRole("button", { name: "Article Actions" })
  ).toBeDefined();

  fireEvent.click(screen.getByRole("button", { name: "Back to Articles" }));
  expect(onBack).toHaveBeenCalledTimes(1);
});
