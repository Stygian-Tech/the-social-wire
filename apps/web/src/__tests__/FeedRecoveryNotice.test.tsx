import { afterEach, describe, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";

import { FeedRecoveryNotice } from "@/components/Wire/FeedRecoveryNotice";

afterEach(cleanup);

describe("FeedRecoveryNotice", () => {
  const edition = {
    source: "ranked" as const,
    degraded: false,
    generatedAt: "2026-10-16T01:43:48Z",
  };

  it("does not show a notice for healthy editions", () => {
    render(<FeedRecoveryNotice edition={edition} />);
    expect(screen.queryByRole("status")).toBeNull();
  });

  it("explains limited Circle coverage without calling a current edition stale", () => {
    render(<FeedRecoveryNotice edition={{ ...edition, degraded: true }} circle />);
    expect(screen.getByRole("status").textContent).toContain("Limited Network Coverage");
    expect(screen.getByText(/Some stories from your network may be missing/)).toBeDefined();
    expect(screen.queryByText(/Last Updated/)).toBeNull();
  });

  it("shows the original edition timestamp for bounded stale serving", () => {
    const { container } = render(
      <FeedRecoveryNotice edition={{ ...edition, source: "stale_generation", degraded: true }} />,
    );
    expect(screen.getByRole("status").textContent).toContain("Updates Are Delayed");
    expect(screen.getByText(/last available edition/)).toBeDefined();
    expect(container.querySelector("time")?.dateTime).toBe(edition.generatedAt);
    expect(container.querySelector("time")?.textContent).toContain("UTC");
    expect(screen.queryByText("Limited Network Coverage")).toBeNull();
  });

  it("does not present Circle's candidate fetch time as its graph freshness", () => {
    const { container } = render(
      <FeedRecoveryNotice edition={{ ...edition, source: "stale_generation", degraded: true }} circle />,
    );
    expect(screen.getByRole("status").textContent).toContain("Limited Network Coverage");
    expect(screen.getByText(/Your Circle is refreshing/)).toBeDefined();
    expect(screen.queryByText(/Last Updated/)).toBeNull();
    expect(container.querySelector("time")).toBeNull();
  });

  it("keeps the recovery explanation if a timestamp is unavailable", () => {
    render(<FeedRecoveryNotice edition={{ ...edition, source: "stale_generation", generatedAt: "invalid" }} />);
    expect(screen.getByRole("status")).toBeDefined();
    expect(screen.queryByText(/Last Updated/)).toBeNull();
  });

  it("explains degraded Wire coverage", () => {
    render(<FeedRecoveryNotice edition={{ ...edition, degraded: true }} />);
    expect(screen.getByRole("status").textContent).toContain("The Wire Is Refreshing");
  });
});
