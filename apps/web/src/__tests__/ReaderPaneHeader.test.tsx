import { expect, it, mock } from "bun:test";
import { fireEvent, render, screen } from "@testing-library/react";
import type React from "react";
import type { EntryDetail } from "@/lib/atprotoClient";

mock.module("@/components/EntryDetail/ArticleSocialToolbar", () => ({
  ArticleSocialToolbar: ({
    entry,
    variant,
  }: {
    entry: EntryDetail | null;
    variant?: string;
  }) =>
    entry && variant === "menu" ? (
      <button type="button" aria-label="Article Actions" />
    ) : null,
}));

mock.module("@/components/ui/button", () => ({
  Button: ({
    children,
    ...props
  }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button {...props}>{children}</button>
  ),
}));

const entry: EntryDetail = {
  entryId: "at://did:plc:author/site.standard.document/article",
  title: "A Better Article Header",
  publishedAt: "2026-07-29T00:00:00.000Z",
  contentHtml: "<p>Article body</p>",
};

it("shows the selected title and a single action menu in the reader header", async () => {
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
