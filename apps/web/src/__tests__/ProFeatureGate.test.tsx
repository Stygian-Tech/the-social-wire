import { afterAll, afterEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as entitlements from "@/hooks/useProEntitlements";
import { ProFeatureGate } from "@/components/Pro/ProFeatureGate";
const access = spyOn(entitlements, "useProEntitlements");
afterEach(() => { cleanup(); access.mockReset(); });
function setAccess(value: Partial<ReturnType<typeof entitlements.useProEntitlements>>) {
  access.mockReturnValue({ isPro: false, isPending: false, isError: false, isFetching: false, refetch: mock(async () => ({})), ...value } as ReturnType<typeof entitlements.useProEntitlements>);
}
it("does not mount protected children while pending, free, or unavailable", () => {
  const mount = mock(() => <p>Private Workspace</p>);
  for (const value of [{ isPending: true }, {}, { isError: true }]) {
    setAccess(value);
    const Child = mount;
    const view = render(<ProFeatureGate><Child /></ProFeatureGate>);
    expect(screen.queryByText("Private Workspace")).toBeNull();
    view.unmount();
  }
  expect(mount).not.toHaveBeenCalled();
});
it("unmounts protected content after downgrade and supports retry", () => {
  setAccess({ isPro: true });
  const view = render(<ProFeatureGate><p>Private Workspace</p></ProFeatureGate>);
  expect(screen.getByText("Private Workspace")).toBeTruthy();
  const refetch = mock(async () => ({}));
  setAccess({ refetch } as unknown as Partial<ReturnType<typeof entitlements.useProEntitlements>>);
  view.rerender(<ProFeatureGate><p>Private Workspace</p></ProFeatureGate>);
  expect(screen.queryByText("Private Workspace")).toBeNull();
  expect(screen.getByText(/Subscriptions are coming soon/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Retry Pro Access" }));
  expect(refetch).toHaveBeenCalledTimes(1);
});

afterAll(() => access.mockRestore());
