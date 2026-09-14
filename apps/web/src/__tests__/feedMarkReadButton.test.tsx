import { afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";

import { FeedMarkReadButton } from "@/app/read/FeedMarkReadButton";
import * as AgeActions from "@/hooks/useFeedReadAgeActions";
import * as AuthHook from "@/hooks/useAuth";
import type { ReadAgeOption } from "@/lib/feedReadAgeClient";

const ages: ReadAgeOption[] = [
  { days: 1, before: "2026-09-02T05:00:00Z", count: 12 },
  { days: 3, before: "2026-08-31T05:00:00Z", count: 4 },
];
const loadOptions = mock(async (onOptions?: (options: ReadAgeOption[]) => void, signal?: AbortSignal) => { void onOptions; void signal; return ages; });
const markBefore = mock(async (before: string) => { void before; });
const markAll = mock(() => {});
const props = {
  scope: { kind: "subscribed" as const },
  displayName: "Subscribed",
  onMarkAllRead: markAll,
};
let restore: () => void;

beforeAll(() => {
  for (const key of ["Element", "HTMLElement", "Node", "DOMRect"] as const) {
    Object.defineProperty(globalThis, key, { configurable: true, value: window[key] });
  }
  Object.defineProperty(globalThis, "getComputedStyle", {
    configurable: true, value: window.getComputedStyle.bind(window),
  });
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  });
  Object.defineProperty(globalThis, "requestAnimationFrame", {
    configurable: true,
    value: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0),
  });
  Object.defineProperty(globalThis, "cancelAnimationFrame", {
    configurable: true, value: (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
  });
});
beforeEach(() => {
  loadOptions.mockReset().mockImplementation(async () => ages);
  markBefore.mockReset().mockImplementation(async () => {});
  markAll.mockClear();
  const ageSpy = spyOn(AgeActions, "useFeedReadAgeActions").mockReturnValue({ loadOptions, markBefore });
  const authSpy = spyOn(AuthHook, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" } } as ReturnType<typeof AuthHook.useAuth>);
  restore = () => { ageSpy.mockRestore(); authSpy.mockRestore(); };
});
afterEach(() => { cleanup(); restore(); });

async function openMenu() {
  fireEvent.contextMenu(screen.getByRole("button", { name: "Mark All As Read" }));
  return screen.findByRole("menu", { name: "Mark Older Stories As Read" });
}

describe("FeedMarkReadButton", () => {
  it("loads represented calendar ages on right-click and confirms the selected cutoff", async () => {
    render(<FeedMarkReadButton {...props} />);
    expect(loadOptions).not.toHaveBeenCalled();
    const menu = await openMenu();
    const oneDay = await within(menu).findByRole("menuitem", { name: "Older Than 1 Day, 12 Unread Stories" });
    expect(within(menu).getByRole("menuitem", { name: "Older Than 3 Days, 4 Unread Stories" })).toBeDefined();
    expect(within(menu).queryByText("2 Days")).toBeNull();
    expect(markAll).not.toHaveBeenCalled();
    fireEvent.click(oneDay);
    const dialog = await screen.findByRole("dialog", { name: "Mark Older Stories As Read?" });
    expect(within(dialog).getByText(/your local time/)).toBeDefined();
    expect(within(dialog).getByText(/Newer stories stay unread/)).toBeDefined();
    expect(markBefore).not.toHaveBeenCalled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Mark As Read" }));
    await waitFor(() => expect(markBefore).toHaveBeenCalledWith(ages[0].before));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(markAll).not.toHaveBeenCalled();
  });

  it("keeps ordinary click and cancellation behavior", async () => {
    render(<FeedMarkReadButton {...props} />);
    fireEvent.click(screen.getByRole("button", { name: "Mark All As Read" }));
    const dialog = await screen.findByRole("dialog", { name: "Mark All As Read?" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(markAll).not.toHaveBeenCalled();
    expect(loadOptions).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Mark All As Read" }));
    fireEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Mark All As Read" }));
    expect(markAll).toHaveBeenCalledTimes(1);
  });

  it("shows loading and retries a failed lookup without marking the feed", async () => {
    let reject!: (error: Error) => void;
    loadOptions.mockImplementationOnce(() => new Promise((_, rejectPromise) => { reject = rejectPromise; }));
    render(<FeedMarkReadButton {...props} />);
    await openMenu();
    expect(await screen.findByText("Loading Ages…")).toBeDefined();
    await act(async () => reject(new Error("offline")));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Couldn’t Load Ages. Retry" }));
    expect(await screen.findByRole("menuitem", { name: "Older Than 1 Day, 12 Unread Stories" })).toBeDefined();
    expect(loadOptions).toHaveBeenCalledTimes(2);
    expect(markAll).not.toHaveBeenCalled();
  });

  it("shows an empty state and refreshes when reopened", async () => {
    loadOptions.mockResolvedValueOnce([]);
    render(<FeedMarkReadButton {...props} />);
    const menu = await openMenu();
    expect(await within(menu).findByText("No Older Unread Stories")).toBeDefined();
    fireEvent.keyDown(menu, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
    await openMenu();
    expect(await screen.findByRole("menuitem", { name: "Older Than 1 Day, 12 Unread Stories" })).toBeDefined();
  });

  it("retains confirmation on failure and prevents double submission while pending", async () => {
    let reject!: (error: Error) => void;
    markBefore.mockImplementationOnce(() => new Promise((_, rejectPromise) => { reject = rejectPromise; }));
    render(<FeedMarkReadButton {...props} />);
    await openMenu();
    fireEvent.click(await screen.findByRole("menuitem", { name: "Older Than 3 Days, 4 Unread Stories" }));
    const dialog = await screen.findByRole("dialog");
    fireEvent.click(within(dialog).getByRole("button", { name: "Mark As Read" }));
    expect(within(dialog).getByRole("button", { name: "Marking…" }).hasAttribute("disabled")).toBe(true);
    expect(within(dialog).getByRole("button", { name: "Cancel" }).hasAttribute("disabled")).toBe(true);
    await act(async () => reject(new Error("offline")));
    expect((await screen.findByRole("alert")).textContent).toContain("Couldn’t Mark Stories As Read");
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
    expect(markBefore).toHaveBeenCalledTimes(1);
    expect(markAll).not.toHaveBeenCalled();
  });

  it("dismisses old confirmations when the feed changes", async () => {
    const view = render(<FeedMarkReadButton {...props} />);
    await openMenu();
    fireEvent.click(await screen.findByRole("menuitem", { name: "Older Than 1 Day, 12 Unread Stories" }));
    await screen.findByRole("dialog");
    view.rerender(<FeedMarkReadButton {...props} scope={{ kind: "following" }} displayName="Following" />);
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(markBefore).not.toHaveBeenCalled();
  });

  it("does not open a menu or mutate when disabled", () => {
    render(<FeedMarkReadButton {...props} disabled />);
    const button = screen.getByRole("button", { name: "Mark All As Read" });
    fireEvent.contextMenu(button);
    fireEvent.click(button);
    expect(screen.queryByRole("menu")).toBeNull();
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(loadOptions).not.toHaveBeenCalled();
  });
});


it("renders partial ages, then enables completed counts and the week option", async () => {
  let publish!: (options: ReadAgeOption[]) => void;
  let finish!: (options: ReadAgeOption[]) => void;
  loadOptions.mockImplementationOnce((onOptions) => {
    publish = onOptions!;
    return new Promise((resolve) => { finish = resolve; });
  });
  render(<FeedMarkReadButton {...props} />);
  await openMenu();
  const week = [{ days: 7, before: ages[1].before, count: 4 }];
  await act(async () => publish(week));
  const partial = await screen.findByRole("menuitem", { name: "Older Than 1 Week, 4+ Unread Stories" });
  expect(partial.getAttribute("aria-disabled")).toBe("true");
  expect(screen.getByText("Counting Stories…")).toBeDefined();
  fireEvent.click(partial);
  expect(screen.queryByRole("dialog")).toBeNull();
  await act(async () => finish([{ ...week[0], count: 20 }]));
  const complete = await screen.findByRole("menuitem", { name: "Older Than 1 Week, 20 Unread Stories" });
  expect(complete.getAttribute("aria-disabled")).not.toBe("true");
  fireEvent.click(complete);
  expect(await screen.findByRole("dialog")).toBeDefined();
});

it("clears partial ages on failure and aborts when closed", async () => {
  let publish!: (options: ReadAgeOption[]) => void;
  let fail!: (error: Error) => void;
  let signal!: AbortSignal;
  loadOptions.mockImplementationOnce((onOptions, pendingSignal) => {
    publish = onOptions!;
    signal = pendingSignal!;
    return new Promise((_, reject) => { fail = reject; });
  });
  render(<FeedMarkReadButton {...props} />);
  const menu = await openMenu();
  await act(async () => publish(ages));
  await act(async () => fail(new Error("offline")));
  expect(await screen.findByText("Couldn’t Load Ages. Retry")).toBeDefined();
  expect(screen.queryByText("1 Day")).toBeNull();
  fireEvent.keyDown(menu, { key: "Escape" });
  await waitFor(() => expect(signal.aborted).toBe(true));
});
