import { afterEach, beforeAll, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { FeedSettingsSection } from "@/components/Account/FeedSettingsSection";
import * as Appearance from "@/components/Account/AppearanceSettingsSection";
import * as ReadLater from "@/components/Account/ReadLaterSettingsSection";
import * as PDSReadState from "@/components/Account/PDSReadStateSettingsSection";
import * as FeedPreferences from "@/hooks/useFeedDisplayPreferences";
import * as ReadLaterPreferences from "@/hooks/useReadLaterPreferences";
import { DEFAULT_FEED_DISPLAY_PREFERENCES } from "@/lib/feedPreferences";
import { findReadLaterService } from "@/lib/readLaterServices";

const setFeedVisible = mock(() => undefined);
const setFeedUnreadCountVisible = mock(() => undefined);

beforeAll(() => {
  for (const name of ["HTMLElement", "HTMLInputElement", "Element", "Node", "PointerEvent"] as const) {
    Object.defineProperty(globalThis, name, { configurable: true, value: window[name] });
  }
});

beforeEach(() => {
  setFeedVisible.mockClear();
  setFeedUnreadCountVisible.mockClear();
  spyOn(Appearance, "AppearanceSettingsSection").mockImplementation(() => <></>);
  spyOn(ReadLater, "ReadLaterSettingsSection").mockImplementation(() => <></>);
  spyOn(PDSReadState, "PDSReadStateSettingsSection").mockImplementation(() => <></>);
  spyOn(ReadLaterPreferences, "useConfiguredReadLaterService").mockReturnValue({
    isLoading: false, data: null, serviceId: "latr-link",
    service: findReadLaterService("latr-link"), sembleConnection: null,
  });
  spyOn(FeedPreferences, "useFeedDisplayPreferences").mockReturnValue({
    preferences: {
      ...DEFAULT_FEED_DISPLAY_PREFERENCES,
      showWire: false, showCircle: false, showFinance: false,
      visibleFeeds: ["readLater", "archive"],
    },
    setFeedVisible, setFeedUnreadCountVisible,
    setDiscoveryFeedVisible: () => undefined,
    setRssArticleOpenInReader: () => undefined,
    setHideSportsScores: () => undefined,
    setHideFinancePerformance: () => undefined,
    isLoading: false,
    isPending: false, error: null,
  });
});

afterEach(() => {
  cleanup();
  mock.restore();
});

test("all feeds expose independent visibility controls", () => {
  render(<FeedSettingsSection />);
  expect(screen.queryByText("Always Visible")).toBeNull();
  for (const label of ["The Wire", "Your Circle", "Finance", "Subscribed", "Following"]) {
    expect(screen.getByRole("switch", { name: `Show ${label}` })).toBeDefined();
  }
  fireEvent.click(screen.getByRole("switch", { name: "Show Read Later" }));
  expect(setFeedVisible).toHaveBeenCalledWith("readLater", false);
  fireEvent.click(screen.getByRole("switch", { name: "Show Archive" }));
  expect(setFeedVisible).toHaveBeenCalledWith("archive", false);
});

test("disables counts for explicitly hidden feeds", () => {
  render(<FeedSettingsSection />);
  fireEvent.click(screen.getByRole("switch", { name: "Show Subscribed Count" }));
  expect(setFeedUnreadCountVisible).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("switch", { name: "Show Following Count" }));
  expect(setFeedUnreadCountVisible).not.toHaveBeenCalled();
});
