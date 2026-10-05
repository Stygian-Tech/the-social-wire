import { beforeEach, afterEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as ConsentDialog from "@/components/SportsPublicInterestDialog";
import { SportsFeedFollowButton } from "@/components/SportsFeedFollowButton";
import { acknowledgeSportsPublicInterests, readSportsPublicInterestConsent } from "@/lib/sportsPublicInterestConsent";
import type { SportsEntity, SportsSelection } from "@/lib/sportsFeedClient";

// The real nested modal is covered by SportsCustomize.test.tsx. Keep these
// atomic action tests independent of Base UI's global focus/scroll machinery.
let restoreDialog: (() => void) | undefined;
let restoreHTMLElement: (() => void) | undefined;
beforeEach(() => {
  // Base UI Button needs only the native element constructor, not modal globals.
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "HTMLElement");
  Object.defineProperty(globalThis, "HTMLElement", { configurable: true, writable: true, value: window.HTMLElement });
  restoreHTMLElement = () => { if (descriptor) Object.defineProperty(globalThis, "HTMLElement", descriptor); else Reflect.deleteProperty(globalThis, "HTMLElement"); };
  const dialog = spyOn(ConsentDialog, "SportsPublicInterestDialog").mockImplementation(({ open, onAccept, onCancel }) => open ? <div role="dialog" aria-label="Your Sports Interests Are Public"><button type="button" onClick={onCancel}>Cancel</button><button type="button" onClick={onAccept}>I Understand</button></div> : <></>);
  restoreDialog = () => dialog.mockRestore();
});
afterEach(() => { cleanup(); restoreDialog?.(); restoreHTMLElement?.(); window.localStorage.clear(); });

const team: SportsEntity = { id: "racing-bulls", name: "Racing Bulls", kind: "team", active: true, competitionIDs: ["f1"], sportID: "motorsport", aliases: ["VCARB"] };
const saveMock = () => mock(async (args: { selection: SportsSelection; remove: boolean }) => { void args; return undefined; });
const props = (viewerDID: string) => ({ entity: team, selections: [] as SportsSelection[], save: saveMock(), saving: false, loading: false, signedIn: true, viewerDID });
const button = () => screen.getByRole("button", { name: "Follow" }) as HTMLButtonElement;

it("requires consent before following the selected canonical entity", async () => {
  const state = props("did:plc:direct-follow-consent");
  render(<SportsFeedFollowButton {...state} />);
  fireEvent.click(button());
  expect(state.save).not.toHaveBeenCalled();
  expect(screen.getByRole("dialog", { name: "Your Sports Interests Are Public" })).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "I Understand" }));
  await waitFor(() => expect(state.save).toHaveBeenCalledTimes(1));
  const call = state.save.mock.calls[0]![0];
  expect(call).toMatchObject({ selection: { reference: team.id, action: "follow" }, remove: false });
  expect(Number.isFinite(Date.parse(call.selection.createdAt))).toBe(true);
  expect(call.selection.updatedAt).toBe(call.selection.createdAt);
  expect(readSportsPublicInterestConsent(state.viewerDID)).toBe(true);
  expect(screen.queryByRole("dialog")).toBeNull();
});

it("cancelling consent does not follow or record an acknowledgement", () => {
  const state = props("did:plc:direct-follow-cancel");
  render(<SportsFeedFollowButton {...state} />);
  fireEvent.click(button());
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(state.save).not.toHaveBeenCalled();
  expect(readSportsPublicInterestConsent(state.viewerDID)).toBe(false);
});

it("uses remembered consent and replaces an exact mute while preserving creation time", async () => {
  const state = props("did:plc:direct-follow-existing-mute");
  acknowledgeSportsPublicInterests(state.viewerDID);
  const previous: SportsSelection = { reference: team.id, action: "mute", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-02T00:00:00.000Z" };
  render(<SportsFeedFollowButton {...state} selections={[previous]} />);
  fireEvent.click(button());
  await waitFor(() => expect(state.save).toHaveBeenCalledTimes(1));
  expect(state.save.mock.calls[0]![0]).toMatchObject({ selection: { reference: team.id, action: "follow", createdAt: previous.createdAt }, remove: false });
  expect(state.save.mock.calls[0]![0].selection.updatedAt).not.toBe(previous.updatedAt);
  expect(screen.queryByRole("dialog")).toBeNull();
});

it("shows an existing follow without removing it when clicked", () => {
  const state = props("did:plc:direct-follow-existing");
  const followed: SportsSelection = { reference: team.id, action: "follow", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z" };
  render(<SportsFeedFollowButton {...state} selections={[followed]} />);
  const following = screen.getByRole("button", { name: "Following" }) as HTMLButtonElement;
  expect(following.disabled).toBe(true);
  fireEvent.click(following);
  expect(state.save).not.toHaveBeenCalled();
});

it("blocks writes while signed out, loading selections, saving, or missing viewer identity", () => {
  const state = props("did:plc:direct-follow-disabled");
  const mounted = render(<SportsFeedFollowButton {...state} signedIn={false} />);
  expect(button().disabled).toBe(true);
  mounted.rerender(<SportsFeedFollowButton {...state} loading />);
  expect(button().disabled).toBe(true);
  mounted.rerender(<SportsFeedFollowButton {...state} saving />);
  expect((screen.getByRole("button") as HTMLButtonElement).disabled).toBe(true);
  mounted.rerender(<SportsFeedFollowButton {...state} viewerDID={undefined} />);
  expect(button().disabled).toBe(true);
  expect(state.save).not.toHaveBeenCalled();
});

it("discards a pending consent handoff when the parent changes account or entity", () => {
  const first = props("did:plc:direct-follow-before-switch");
  const view = (state: ReturnType<typeof props>) => <SportsFeedFollowButton key={`${state.viewerDID}:${state.entity.id}`} {...state} />;
  const mounted = render(view(first));
  fireEvent.click(button());
  expect(screen.getByRole("dialog", { name: "Your Sports Interests Are Public" })).toBeTruthy();
  const next = { ...props("did:plc:direct-follow-after-switch"), entity: { ...team, id: "red-bull", name: "Red Bull Racing" } };
  mounted.rerender(view(next));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(first.save).not.toHaveBeenCalled();
  expect(next.save).not.toHaveBeenCalled();
  expect(readSportsPublicInterestConsent(first.viewerDID)).toBe(false);
  expect(readSportsPublicInterestConsent(next.viewerDID)).toBe(false);
});


it("keeps Follow available after a failed write and retries without repeating consent", async () => {
  const state = props("did:plc:direct-follow-retry");
  acknowledgeSportsPublicInterests(state.viewerDID);
  state.save.mockRejectedValueOnce(new Error("PDS Write Failed"));
  render(<SportsFeedFollowButton {...state} />);
  fireEvent.click(button());
  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("PDS Write Failed"));
  expect(button().disabled).toBe(false);
  expect(screen.queryByRole("button", { name: "Following" })).toBeNull();
  fireEvent.click(button());
  await waitFor(() => expect(state.save).toHaveBeenCalledTimes(2));
  expect(screen.queryByRole("alert")).toBeNull();
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(state.save.mock.calls.every(([call]) => call.remove === false && call.selection.reference === team.id)).toBe(true);
});
