export type ThemePreference = "light" | "dark" | "system";
export type ComputedTheme = "light" | "dark";
export type FontPreference = "sans" | "serif" | "mono";

export const THEME_STORAGE_KEY = "the-social-wire.theme.v1";
export const FONT_STORAGE_KEY = "the-social-wire.font.v1";
export const BOLD_TEXT_STORAGE_KEY = "the-social-wire.bold-text.v1";

export function isThemePreference(
  value: string | null,
): value is ThemePreference {
  return value === "light" || value === "dark" || value === "system";
}

export function isFontPreference(
  value: string | null,
): value is FontPreference {
  return value === "sans" || value === "serif" || value === "mono";
}

export function isBoldTextPreference(value: string | null): value is "1" | "0" {
  return value === "1" || value === "0";
}

export function resolveComputedTheme(
  preference: ThemePreference,
  systemDark: boolean,
): ComputedTheme {
  if (preference === "dark") return "dark";
  if (preference === "light") return "light";
  return systemDark ? "dark" : "light";
}
