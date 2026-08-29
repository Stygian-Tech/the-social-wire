import { afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";

import { OpmlImportPanel } from "@/components/Account/OpmlImportPanel";

beforeAll(() => {
  Object.defineProperty(globalThis, "HTMLElement", {
    configurable: true,
    value: window.HTMLElement,
  });
});

afterEach(cleanup);

const opml = `<opml version="2.0"><body>
  <outline text="Existing Feed" xmlUrl="https://existing.example/feed" />
  <outline text="Fresh Feed" xmlUrl="https://fresh.example/feed" />
  <outline text="Duplicate Fresh Feed" xmlUrl="http://fresh.example/feed" />
  <outline text="Retry Feed" xmlUrl="https://retry.example/feed" />
</body></opml>`;

describe("OpmlImportPanel", () => {
  it("dedupes the review, disables existing feeds, and supports selective import", async () => {
    const onImport = mock(async (feeds, onProgress) => {
      onProgress({
        completed: feeds.length,
        total: feeds.length,
        feed: feeds.at(-1)!,
        status: "failed",
      });
      return {
        imported: [feeds[0]!],
        skippedExisting: [],
        failed: [{ feed: feeds[1]!, message: "Temporary PDS failure" }],
      };
    });

    render(
      <OpmlImportPanel
        existingFeedUrls={["http://EXISTING.example/feed"]}
        existingSubscriptionsLoading={false}
        onImport={onImport}
      />
    );

    const input = screen.getByLabelText("Choose OPML File") as HTMLInputElement;
    fireEvent.change(input, {
      target: {
        files: [new File([opml], "subscriptions.opml", { type: "text/x-opml" })],
      },
    });

    await waitFor(() => {
      expect(screen.getByText("2 New · 1 Already Subscribed · 1 Duplicate Feed Removed")).toBeDefined();
    });

    const existing = screen.getByRole("checkbox", { name: /Existing Feed/ }) as HTMLInputElement;
    const fresh = screen.getByRole("checkbox", { name: /Fresh Feed/ }) as HTMLInputElement;
    const retry = screen.getByRole("checkbox", { name: /Retry Feed/ }) as HTMLInputElement;
    expect(existing.disabled).toBe(true);
    expect(existing.checked).toBe(false);
    expect(fresh.checked).toBe(true);
    expect(retry.checked).toBe(true);
    expect(screen.getByText("2 Selected")).toBeDefined();

    fireEvent.click(fresh);
    expect(screen.getByText("1 Selected")).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Select All" }));
    expect(fresh.checked).toBe(true);
    expect(retry.checked).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Import 2 Feeds" }));

    await waitFor(() => {
      expect(onImport).toHaveBeenCalledTimes(1);
      expect(screen.getByRole("button", { name: "Retry 1 Feed" })).toBeDefined();
    });
    expect(fresh.checked).toBe(false);
    expect(retry.checked).toBe(true);
    expect(screen.getByText(/1 feed could not be imported/)).toBeDefined();
  });

  it("shows an accessible error for malformed OPML", async () => {
    render(
      <OpmlImportPanel
        existingFeedUrls={[]}
        existingSubscriptionsLoading={false}
        onImport={async () => ({ imported: [], skippedExisting: [], failed: [] })}
      />
    );

    fireEvent.change(screen.getByLabelText("Choose OPML File"), {
      target: {
        files: [new File(["<opml><body></opml>"], "broken.opml")],
      },
    });

    expect((await screen.findByRole("alert")).textContent).toContain("not valid XML");
  });

  it("waits for existing subscription dedupe before accepting a file", () => {
    const { rerender } = render(
      <OpmlImportPanel
        existingFeedUrls={[]}
        existingSubscriptionsLoading
        onImport={async () => ({ imported: [], skippedExisting: [], failed: [] })}
      />
    );

    expect(screen.getByRole("status").textContent).toContain(
      "Checking Existing Subscriptions"
    );
    expect(screen.queryByLabelText("Choose OPML File")).toBeNull();

    rerender(
      <OpmlImportPanel
        existingFeedUrls={[]}
        existingSubscriptionsLoading={false}
        onImport={async () => ({ imported: [], skippedExisting: [], failed: [] })}
      />
    );

    expect(screen.getByLabelText("Choose OPML File")).toBeDefined();
  });

  it("blocks importing when existing subscriptions cannot be loaded", () => {
    render(
      <OpmlImportPanel
        existingFeedUrls={[]}
        existingSubscriptionsLoading={false}
        existingSubscriptionsError="Could not load existing subscriptions."
        onImport={async () => ({ imported: [], skippedExisting: [], failed: [] })}
      />
    );

    expect(screen.getByRole("alert").textContent).toContain(
      "Could not load existing subscriptions"
    );
    expect(screen.queryByLabelText("Choose OPML File")).toBeNull();
  });

  it("resets the account-page importer after a successful import", async () => {
    render(
      <OpmlImportPanel
        existingFeedUrls={[]}
        existingSubscriptionsLoading={false}
        onImport={async (feeds) => ({
          imported: [...feeds],
          skippedExisting: [],
          failed: [],
        })}
      />
    );

    fireEvent.change(screen.getByLabelText("Choose OPML File"), {
      target: {
        files: [
          new File(
            [
              '<opml version="2.0"><body><outline text="Fresh Feed" xmlUrl="https://fresh.example/feed" /></body></opml>',
            ],
            "subscriptions.opml"
          ),
        ],
      },
    });

    fireEvent.click(await screen.findByRole("button", { name: "Import 1 Feed" }));

    const resetButton = await screen.findByRole("button", {
      name: "Import Another OPML File",
    });
    expect(screen.getByText("1 Feed Imported")).toBeDefined();

    fireEvent.click(resetButton);

    expect(screen.getByLabelText("Choose OPML File")).toBeDefined();
    expect(screen.queryByText("subscriptions.opml")).toBeNull();
  });
});
