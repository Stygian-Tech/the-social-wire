import { afterEach, beforeAll, describe, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";

import { RssArticleReaderDialogView } from "@/components/EntryDetail/RssArticleReaderDialog";

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
    const { container } = render(
      <RssArticleReaderDialogView
        open
        entryId="rssentry:article"
        originalUrl="https://example.com/article"
        title="Native RSS Reader"
        onClose={() => undefined}
        entryQuery={{
          data: {
            contentHtml:
              '<h1>Feed Content</h1><p>Rendered by the app.</p><iframe src="https://example.com"></iframe>',
          },
          isLoading: false,
          error: null,
        }}
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
