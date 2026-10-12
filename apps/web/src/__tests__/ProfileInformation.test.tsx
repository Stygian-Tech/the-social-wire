import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as Profiles from "@/hooks/useViewerProfile";
import { ProfileInformation } from "@/components/Account/ProfileInformation";

const originalMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }));
afterAll(() => { if (originalMedia) Object.defineProperty(window, "matchMedia", originalMedia); else Reflect.deleteProperty(window, "matchMedia"); });
let state: { data: Profiles.ViewerProfileSlice | null; isLoading: boolean; refetch: ReturnType<typeof mock> };
let restore: () => void;
beforeEach(() => {
  state = { data: { did: "did:plc:viewer", displayName: "Local Viewer", handle: "viewer.local.test", description: "First line\nSecond line", followersCount: 12, followsCount: 0, postsCount: 48 }, isLoading: false, refetch: mock(async () => undefined) };
  const profile = spyOn(Profiles, "useViewerProfile").mockImplementation(() => state as unknown as ReturnType<typeof Profiles.useViewerProfile>);
  restore = () => profile.mockRestore();
});
afterEach(() => { cleanup(); restore(); });

describe("Profile information", () => {
  it("displays the viewer identity, biography, and available social counts", () => {
    render(<ProfileInformation />);
    expect(screen.getByRole("heading", { name: "Local Viewer" })).toBeTruthy();
    expect(screen.getByText("@viewer.local.test")).toBeTruthy();
    expect(screen.getByText("First line Second line")).toBeTruthy();
    expect(screen.getByText("Followers").nextElementSibling?.textContent).toBe("12");
    expect(screen.getByText("Following").nextElementSibling?.textContent).toBe("0");
    expect(screen.getByText("Posts").nextElementSibling?.textContent).toBe("48");
    expect(screen.getByRole("heading", { name: "Local Viewer" }).closest("section")?.id).toBe("profile");
  });
  it("omits unknown counts and keeps a DID fallback readable", () => {
    state.data = { did: "did:plc:viewer", handle: "did:plc:viewer", description: "Repo fallback profile" };
    render(<ProfileInformation />);
    expect(screen.getByRole("heading", { name: "did:plc:viewer" })).toBeTruthy();
    expect(screen.queryByText("@did:plc:viewer")).toBeNull();
    expect(screen.queryByText("Followers")).toBeNull();
    expect(screen.queryByText("Following")).toBeNull();
  });
  it("shows loading and provides retry when profile retrieval fails", () => {
    state.data = null; state.isLoading = true;
    const view = render(<ProfileInformation />);
    expect(screen.getByRole("status", { name: "Loading Profile" })).toBeTruthy();
    state.isLoading = false;
    view.rerender(<ProfileInformation />);
    expect(screen.getByRole("heading", { name: "Profile Unavailable" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(state.refetch).toHaveBeenCalledTimes(1);
  });
});
