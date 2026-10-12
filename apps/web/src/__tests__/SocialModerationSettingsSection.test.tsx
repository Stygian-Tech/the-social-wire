import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { interpretLabelValueDefinition } from "@atproto/api";
import * as Auth from "@/hooks/useAuth";
import * as Hook from "@/hooks/useSocialModerationSettings";
import { SocialModerationSettingsSection } from "@/components/Account/SocialModerationSettingsSection";

const did = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa";
const definition = interpretLabelValueDefinition({ identifier: "spoiler", severity: "inform", blurs: "none", locales: [{ lang: "en", name: "Spoiler", description: "Contains Spoilers" }], defaultSetting: "warn" }, did);
const mutate = mock((...args: unknown[]) => { void args; });
const lookup = mock(() => {});
let value: ReturnType<typeof Hook.useSocialModerationSettings>;
const restores: (() => void)[] = [];
beforeEach(() => {
  mutate.mockClear(); lookup.mockClear();
  value = { settings: { data: { moderation: { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did, labels: {} }], mutedWords: [], hiddenPosts: [] } }, labelers: [{ did, profile: { did, handle: "labels.example", displayName: "Helpful Labels" }, definitions: [definition], subscribed: true, mandatory: false }] }, isPending: false, isError: false, error: null }, lookup: { mutate: lookup, reset() {}, isPending: false, error: null }, change: { mutate, isPending: false, error: null } } as unknown as typeof value;
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" } } as ReturnType<typeof Auth.useAuth>);
  const hook = spyOn(Hook, "useSocialModerationSettings").mockImplementation(() => value);
  restores.push(() => auth.mockRestore(), () => hook.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

it("loads settings only when opened and writes explicit Show/Warn/Hide actions", () => {
  render(<SocialModerationSettingsSection />);
  expect(screen.queryByText("Helpful Labels")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Manage Labelers" }));
  expect(screen.getByText("Contains Spoilers")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Warn" }).getAttribute("aria-pressed")).toBe("true");
  expect(mutate).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Show" }));
  expect(mutate).toHaveBeenCalledWith({ type: "label", did, label: "spoiler", visibility: "ignore" });
});

it("requires removal confirmation and validates lookup before offering subscription", () => {
  render(<SocialModerationSettingsSection />);
  fireEvent.click(screen.getByRole("button", { name: "Manage Labelers" }));
  fireEvent.click(screen.getByRole("button", { name: "Remove Labeler" }));
  expect(mutate).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("group", { name: "Confirm Labeler Removal" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Remove Labeler" }));
  fireEvent.click(screen.getByRole("button", { name: "Confirm Removal" }));
  expect(mutate.mock.calls[0]?.[0]).toEqual({ type: "unsubscribe", did });
  fireEvent.change(screen.getByRole("textbox", { name: "Add Labeler" }), { target: { value: "new.example" } });
  fireEvent.click(screen.getByRole("button", { name: "Find Labeler" }));
  expect(lookup).toHaveBeenCalledWith("new.example");
  expect(screen.queryByRole("button", { name: "Subscribe" })).toBeNull();
});

it("disables adult labels and hides removal for required labelers", () => {
  const data = value.settings.data!;
  data.labelers[0]!.mandatory = true;
  data.labelers[0]!.definitions = [{ ...definition, flags: ["adult"] }];
  render(<SocialModerationSettingsSection />);
  fireEvent.click(screen.getByRole("button", { name: "Manage Labelers" }));
  expect(screen.getByText("Required")).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Remove Labeler" })).toBeNull();
  const group = screen.getByRole("group", { name: "Spoiler" });
  expect(group.hasAttribute("disabled")).toBe(true);
  expect(within(group).getByRole("button", { name: "Hide" }).getAttribute("aria-pressed")).toBe("true");
});

it("withholds stale labeler controls when moderation reload fails", () => {
  value.settings.isError = true;
  value.settings.error = new Error("Moderation unavailable");
  render(<SocialModerationSettingsSection />);
  fireEvent.click(screen.getByRole("button", { name: "Manage Labelers" }));
  expect(screen.getByRole("alert").textContent).toBe("Moderation unavailable");
  expect(screen.queryByText("Helpful Labels")).toBeNull();
  expect(screen.queryByRole("button", { name: "Show" })).toBeNull();
});
