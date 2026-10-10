import { describe, expect, it } from "bun:test";
import { topicNavigationIsVisible } from "@/lib/topicNavigationVisibility";

describe("Topic Navigation Visibility", () => {
  it("keeps local navigation visible without server capabilities", () => {
    expect(topicNavigationIsVisible(true, undefined, "local")).toBe(true);
    expect(topicNavigationIsVisible(true, false, "local")).toBe(true);
    expect(topicNavigationIsVisible(true, true, "local")).toBe(true);
  });
  it("respects hidden topic preferences in every environment", () => {
    for (const environment of ["local", "dev", "prod", "test"]) {
      for (const enabled of [undefined, false, true]) {
        expect(topicNavigationIsVisible(false, enabled, environment)).toBe(false);
      }
    }
  });
  it("requires confirmed server capabilities outside local builds", () => {
    for (const environment of ["dev", "prod", "test", "preview"]) {
      expect(topicNavigationIsVisible(true, undefined, environment)).toBe(false);
      expect(topicNavigationIsVisible(true, false, environment)).toBe(false);
      expect(topicNavigationIsVisible(true, true, environment)).toBe(true);
    }
  });
});
