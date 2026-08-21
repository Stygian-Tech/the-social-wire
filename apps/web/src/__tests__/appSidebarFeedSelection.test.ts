import { describe, expect, it } from "bun:test";

import {
  currentAppSidebarFeed,
  isAllFeedRouteSelected,
} from "@/components/AppSidebar/appSidebarFeedSelection";

describe("app sidebar feed selection", () => {
  it("keeps Read Later selected while browsing a saved source", () => {
    expect(
      currentAppSidebarFeed({
        pathname: "/saved",
        feedParam: null,
        folderParam: null,
        publicationTab: "subscribed",
      }),
    ).toBe("readLater");
    expect(
      isAllFeedRouteSelected({
        pathname: "/saved",
        sourceParam: "example.com",
        folderParam: null,
      }),
    ).toBe(false);
  });

  it("keeps Subscribed selected while browsing a folder", () => {
    expect(
      currentAppSidebarFeed({
        pathname: "/read",
        feedParam: null,
        folderParam: "engineering",
        publicationTab: "following",
      }),
    ).toBe("subscribed");
    expect(
      isAllFeedRouteSelected({
        pathname: "/read",
        sourceParam: null,
        folderParam: "engineering",
      }),
    ).toBe(false);
  });

  it("keeps the active publication tab selected on publication routes", () => {
    expect(
      currentAppSidebarFeed({
        pathname: "/read/at%3A%2F%2Fdid%3Aplc%3Aexample",
        feedParam: null,
        folderParam: null,
        publicationTab: "following",
      }),
    ).toBe("following");
    expect(
      isAllFeedRouteSelected({
        pathname: "/read/at%3A%2F%2Fdid%3Aplc%3Aexample",
        sourceParam: null,
        folderParam: null,
      }),
    ).toBe(false);
  });

  it("selects All only on an aggregate feed route", () => {
    expect(
      currentAppSidebarFeed({
        pathname: "/read",
        feedParam: "following",
        folderParam: null,
        publicationTab: "subscribed",
      }),
    ).toBe("following");
    expect(
      isAllFeedRouteSelected({
        pathname: "/read",
        sourceParam: null,
        folderParam: null,
      }),
    ).toBe(true);
  });

  it("recognizes The Wire without changing the remembered publication tab", () => {
    expect(
      currentAppSidebarFeed({
        pathname: "/read",
        feedParam: "wire",
        folderParam: null,
        publicationTab: "following",
      }),
    ).toBe("wire");
  });
});
