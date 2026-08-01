import { afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";

mock.module("@/hooks/useEntries", () => ({
  useEntry: () => ({
    data: {
      entryId: "rssentry:article",
      title: "Native RSS Reader",
      publishedAt: "2026-08-01T00:00:00.000Z",
      contentHtml:
        '<h1>Feed Content</h1><p>Rendered by the app.</p><iframe src="https://example.com"></iframe>',
    },
    isLoading: false,
    error: null,
  }),
}));

beforeAll(() => {
  Object.defineProperty(window.HTMLElement.prototype, "showModal", {
    configurable: true,
    value() {
      this.setAttribute("open", "");
    },
  });
});

afterEach(cleanup);

describe("RssArticleReaderDialog", () => {
  it("renders sanitized feed content in the app DOM without an iframe", async () => {
    const { RssArticleReaderDialog } = await import(
      "@/components/EntryDetail/RssArticleReaderDialog"
    );
    const { container } = render(
      <RssArticleReaderDialog
        open
        entryId="rssentry:article"
        originalUrl="https://example.com/article"
        title="Native RSS Reader"
        onClose={() => undefined}
      />,
    );

    expect(screen.getByText("Feed Content")).toBeDefined();
    expect(screen.getByText("Rendered by the app.")).toBeDefined();
    expect(container.querySelector(".article-content")).not.toBeNull();
    expect(container.querySelector("iframe")).toBeNull();
    expect(
      screen
        .getByRole("link", { name: "Open Article on Original Site" })
        .getAttribute("href"),
    ).toBe("https://example.com/article");
  });
});
