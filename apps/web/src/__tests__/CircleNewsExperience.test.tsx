import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as CircleHooks from "@/hooks/useCircleFeed";
import { CircleNewsExperience } from "@/components/Circle/CircleNewsExperience";

const refetchCatalog = mock(() => Promise.resolve());
const refetchEdition = mock(() => Promise.resolve());
let state: ReturnType<typeof CircleHooks.useCircleEdition>;
let restore: () => void;

describe("Circle feed availability messages", () => {
  beforeEach(() => {
    refetchCatalog.mockClear();
    refetchEdition.mockClear();
    state = {
      catalog: {
        data: { enabled: true, available: true },
        isLoading: false,
        isError: false,
        refetch: refetchCatalog,
      },
      data: { pages: [{ stories: [], source: "generation", degraded: false }] },
      isLoading: false,
      isRefetching: false,
      isError: false,
      refetch: refetchEdition,
    } as unknown as typeof state;
    const spy = spyOn(CircleHooks, "useCircleEdition").mockImplementation(() => state);
    restore = () => spy.mockRestore();
  });

  afterEach(() => {
    cleanup();
    restore();
  });

  const show = () => render(<CircleNewsExperience onSelect={() => undefined} />);

  it("explains an empty network feed and retries its edition", () => {
    show();
    expect(screen.getByRole("heading", { name: "Your Circle Is Still Taking Shape" })).toBeDefined();
    expect(screen.getByText(/people you follow and their connections/)).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(refetchEdition).toHaveBeenCalledTimes(1);
    expect(refetchCatalog).not.toHaveBeenCalled();
  });

  it("explains corpus readiness separately and retries the catalog", () => {
    state.catalog.data!.available = false;
    state.data = undefined;
    show();
    expect(screen.getByRole("heading", { name: "Your Circle Is Not Ready Yet" })).toBeDefined();
    expect(screen.queryByText(/people you follow/)).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(refetchCatalog).toHaveBeenCalledTimes(1);
    expect(refetchEdition).not.toHaveBeenCalled();
  });

  it("shows catalog failures rather than claiming insufficient activity", () => {
    state.catalog.isError = true;
    state.catalog.data = undefined;
    show();
    expect(screen.getByRole("heading", { name: "Your Circle Could Not Load" })).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(refetchCatalog).toHaveBeenCalledTimes(1);
    expect(refetchEdition).not.toHaveBeenCalled();
  });

  it("shows a failed refresh even when an empty edition is cached", () => {
    state.isError = true;
    state.error = new Error("The request failed.");
    show();
    expect(screen.getByText("The request failed.")).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(refetchEdition).toHaveBeenCalledTimes(1);
  });

  it("preserves limited coverage information for degraded empty editions", () => {
    state.data!.pages[0]!.degraded = true;
    show();
    expect(screen.getByRole("heading", { name: "Your Circle Is Refreshing" })).toBeDefined();
    expect(screen.getByText(/Network coverage is limited/)).toBeDefined();
  });

  it("does not label a loading catalog as an empty network", () => {
    state.catalog.isLoading = true;
    state.catalog.data = undefined;
    show();
    expect(screen.queryByRole("heading")).toBeNull();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
  });

  it("keeps global disablement distinct from insufficient stories", () => {
    state.catalog.data!.enabled = false;
    show();
    expect(screen.getByRole("heading", { name: "Your Circle Is Unavailable" })).toBeDefined();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
  });
});
