import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Scheduling from "@/hooks/useSkejScheduling";
import * as Navigation from "next/navigation";
import ContentCalendarLayout from "@/app/content-calendar/layout";
import * as Auth from "@/hooks/useAuth";
import * as Accounts from "@/hooks/useBrandAccounts";
import * as Profiles from "@/lib/brandAccounts/brandAccountPublicProfile";
import { ContentCalendarAccount } from "@/components/ContentCalendar/ContentCalendarAccount";
import ContentCalendarPage from "@/app/content-calendar/page";
import type { SkejScheduleSummary } from "@/lib/skej/skejSchedulingClient";
import { localCalendarDate, localDateTimeValue } from "@/components/ContentCalendar/calendarDates";

let cache: QueryClient;
let state: ReturnType<typeof Scheduling.useSkejScheduling>;
const restores: (() => void)[] = [];
const owner = "did:plc:owner", brand = "did:plc:brand";
const time = new Date(Date.now() + 3_600_000);
const item = { did: owner, rkey: "post", scheduleUri: `at://${owner}/app.skej.schedule/post`, scheduledAt: time.toISOString(), status: "scheduled", record: { posts: [{ text: "Planned Content" }] }, attempts: 0 } as unknown as SkejScheduleSummary;
beforeEach(() => {
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  state = { schedules: { data: [item], isPending: false, isError: false, isFetching: false, refetch: mock(async () => ({})) }, readiness: { data: { accountDid: owner, connected: true }, isPending: false, isError: false, refetch: mock(async () => ({})) }, pending: false, schedule: mock(async () => item), cancel: mock(async () => {}), reschedule: mock(async () => {}), connectUrl: "https://skej.test/connect" } as unknown as typeof state;
  const hook = spyOn(Scheduling, "useSkejScheduling").mockImplementation(() => state); restores.push(() => hook.mockRestore());
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: owner } } as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const linked = spyOn(Accounts, "useBrandAccounts").mockReturnValue([brand]); restores.push(() => linked.mockRestore());
  const profiles = spyOn(Profiles, "getBrandAccountPublicProfile").mockImplementation(async did => ({ did, handle: did === owner ? "owner.test" : "brand.test" })); restores.push(() => profiles.mockRestore());
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) { const original = Object.getOwnPropertyDescriptor(globalThis, name); Object.defineProperty(globalThis, name, { configurable: true, value }); restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); }); }
});
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function mount(ui = <ContentCalendarAccount ownerDid={owner} actorDid={owner} />) { return render(<QueryClientProvider client={cache}>{ui}</QueryClientProvider>); }
test("renders selected day posts and confirms cancellation before calling the selected account", async () => {
  mount();
  if (localCalendarDate(time) !== localCalendarDate(new Date())) fireEvent.click(screen.getByRole("button", { name: new RegExp(time.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" })) }));
  expect(screen.getByText("Planned Content")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Cancel Scheduled Post" }));
  expect(state.cancel).not.toHaveBeenCalled();
  fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Cancel Scheduled Post" }));
  await waitFor(() => expect(state.cancel).toHaveBeenCalledWith(item));
});
test("reschedules in local time and refreshes the server-backed list", async () => {
  mount();
  if (localCalendarDate(time) !== localCalendarDate(new Date())) fireEvent.click(screen.getByRole("button", { name: new RegExp(time.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" })) }));
  fireEvent.click(screen.getByRole("button", { name: "Reschedule" }));
  const future = new Date(Date.now() + 86_400_000);
  fireEvent.change(screen.getByLabelText("Publish At"), { target: { value: localDateTimeValue(future) } });
  fireEvent.click(screen.getByRole("button", { name: "Save Time" }));
  await waitFor(() => expect(state.reschedule).toHaveBeenCalledWith(item, new Date(localDateTimeValue(future)).toISOString()));
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  expect(state.schedules.refetch).toHaveBeenCalled();
});
test("filters out another account and opens the tool route with a selected account", async () => {
  mount(<ContentCalendarPage />);
  expect(screen.getByRole("heading", { name: "Content Calendar" })).toBeTruthy();
  fireEvent.change(screen.getByRole("combobox", { name: "Account" }), { target: { value: brand } });
  expect(Scheduling.useSkejScheduling).toHaveBeenLastCalledWith(owner, brand);
  expect(screen.queryByText("Planned Content")).toBeNull();
});
test("shows connection and load failure recovery without inventing records", () => {
  state = { ...state, readiness: { ...state.readiness, data: { accountDid: owner, connected: false } }, schedules: { ...state.schedules, data: undefined, isError: true } } as typeof state;
  mount();
  expect(screen.getByRole("link", { name: "Connect Scheduling" }).getAttribute("href")).toBe(state.connectUrl);
  expect(screen.getByRole("alert").textContent).toContain("Could Not Be Loaded");
  expect(screen.queryByText("No Posts Scheduled for This Day")).toBeNull();
});

test("protects the calendar route when signed out", async () => {
  spyOn(Auth, "useAuth").mockReturnValue({ session: null, isLoading: false } as ReturnType<typeof Auth.useAuth>);
  const replace = mock(() => {});
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ replace } as unknown as ReturnType<typeof Navigation.useRouter>); restores.push(() => router.mockRestore());
  render(<ContentCalendarLayout><p>Private Calendar</p></ContentCalendarLayout>);
  await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
  expect(screen.queryByText("Private Calendar")).toBeNull();
});

test("hides private calendar rows immediately after unlink while keeping the selection explicit", async () => {
  // Unlink visibility is independent of scheduling across the next day or month.
  const selectedDay = new Date();
  selectedDay.setHours(12, 0, 0, 0);
  state = { ...state, schedules: { ...state.schedules, data: [{ ...item, did: brand, scheduledAt: selectedDay.toISOString() }] } } as typeof state;
  const view = mount(<ContentCalendarPage />);
  fireEvent.change(screen.getByRole("combobox", { name: "Account" }), { target: { value: brand } });
  expect(screen.getByText("Planned Content")).toBeTruthy();
  spyOn(Accounts, "useBrandAccounts").mockReturnValue([]);
  view.rerender(<QueryClientProvider client={cache}><ContentCalendarPage /></QueryClientProvider>);
  expect(screen.queryByText("Planned Content")).toBeNull();
  expect(screen.getByRole("alert").textContent).toContain("No Longer Linked");
  expect((screen.getByRole("combobox", { name: "Account" }) as HTMLSelectElement).value).toBe(brand);
});
