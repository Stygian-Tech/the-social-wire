import { describe, expect, it } from "bun:test";

import {
  isBoldTextPreference,
  isFontPreference,
  isThemePreference,
  resolveComputedTheme,
} from "@/lib/appearance";

describe("appearance preferences", () => {
  it("validates supported theme, font, and bold values", () => {
    expect(isThemePreference("system")).toBe(true);
    expect(isThemePreference("light")).toBe(true);
    expect(isThemePreference("dark")).toBe(true);
    expect(isThemePreference("auto")).toBe(false);

    expect(isFontPreference("sans")).toBe(true);
    expect(isFontPreference("serif")).toBe(true);
    expect(isFontPreference("mono")).toBe(true);
    expect(isFontPreference("display")).toBe(false);

    expect(isBoldTextPreference("1")).toBe(true);
    expect(isBoldTextPreference("0")).toBe(true);
    expect(isBoldTextPreference("true")).toBe(false);
  });

  it("resolves explicit themes before the system preference", () => {
    expect(resolveComputedTheme("light", true)).toBe("light");
    expect(resolveComputedTheme("dark", false)).toBe("dark");
    expect(resolveComputedTheme("system", true)).toBe("dark");
    expect(resolveComputedTheme("system", false)).toBe("light");
  });
});
