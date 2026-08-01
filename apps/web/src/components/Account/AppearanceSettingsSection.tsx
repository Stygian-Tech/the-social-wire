"use client";

import {
  Bold,
  Check,
  Code2,
  Monitor,
  Moon,
  Sun,
  Type,
  type LucideIcon,
} from "lucide-react";
import type { CSSProperties } from "react";

import { useAppearance } from "@/hooks/useAppearance";
import type {
  FontPreference,
  ThemePreference,
} from "@/lib/appearance";
import { cn } from "@/lib/utils";

const themeOptions: Array<{
  value: ThemePreference;
  label: string;
  icon: LucideIcon;
}> = [
  { value: "system", label: "System", icon: Monitor },
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
];

const fontOptions: Array<{
  value: FontPreference;
  label: string;
  icon: LucideIcon;
  style: CSSProperties;
}> = [
  {
    value: "sans",
    label: "Sans",
    icon: Type,
    style: { fontFamily: "var(--font-sans-system)" },
  },
  {
    value: "serif",
    label: "Serif",
    icon: Type,
    style: { fontFamily: "var(--font-serif-system)" },
  },
  {
    value: "mono",
    label: "Mono",
    icon: Code2,
    style: { fontFamily: "var(--font-mono-system)" },
  },
];

const optionClassName =
  "flex min-h-12 items-center gap-3 rounded-lg border px-3 py-2 text-left text-sm transition-colors";

export function AppearanceSettingsSection() {
  const {
    theme,
    computedTheme,
    setTheme,
    font,
    setFont,
    boldText,
    setBoldText,
  } = useAppearance();

  return (
    <section className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)]">
      <h2 className="text-sm font-bold">Appearance</h2>
      <div className="mt-4 grid gap-5">
        <div>
          <div className="flex items-center justify-between gap-3">
            <h3 className="text-sm font-medium text-foreground">Theme</h3>
            <span className="text-xs text-muted-foreground">
              {theme === "system"
                ? `System (${computedTheme === "dark" ? "Dark" : "Light"})`
                : theme === "dark"
                  ? "Dark"
                  : "Light"}
            </span>
          </div>
          <div
            role="radiogroup"
            aria-label="Theme"
            className="mt-3 grid gap-2 sm:grid-cols-3"
          >
            {themeOptions.map((option) => {
              const active = option.value === theme;
              return (
                <button
                  key={option.value}
                  type="button"
                  role="radio"
                  aria-checked={active}
                  onClick={() => setTheme(option.value)}
                  className={cn(
                    optionClassName,
                    active
                      ? "border-primary bg-accent text-accent-foreground"
                      : "border-border bg-background text-muted-foreground hover:border-primary/45 hover:text-foreground",
                  )}
                >
                  <option.icon
                    aria-hidden="true"
                    className="size-4 shrink-0 text-primary"
                    strokeWidth={1.9}
                  />
                  <span className="min-w-0 flex-1 font-medium text-foreground">
                    {option.label}
                  </span>
                  {active ? (
                    <Check aria-hidden="true" className="size-4 shrink-0 text-primary" />
                  ) : null}
                </button>
              );
            })}
          </div>
        </div>

        <div>
          <div className="flex items-center justify-between gap-3">
            <h3 className="text-sm font-medium text-foreground">Font</h3>
            <span className="text-xs text-muted-foreground">
              {font === "sans" ? "Sans" : font === "serif" ? "Serif" : "Mono"}
              {boldText ? " + Bold" : ""}
            </span>
          </div>
          <div
            role="radiogroup"
            aria-label="Font"
            className="mt-3 grid gap-2 sm:grid-cols-3"
          >
            {fontOptions.map((option) => {
              const active = option.value === font;
              return (
                <button
                  key={option.value}
                  type="button"
                  role="radio"
                  aria-checked={active}
                  onClick={() => setFont(option.value)}
                  className={cn(
                    optionClassName,
                    active
                      ? "border-primary bg-accent text-accent-foreground"
                      : "border-border bg-background text-muted-foreground hover:border-primary/45 hover:text-foreground",
                  )}
                >
                  <option.icon
                    aria-hidden="true"
                    className="size-4 shrink-0 text-primary"
                    strokeWidth={1.9}
                  />
                  <span
                    className="min-w-0 flex-1 truncate text-base text-foreground"
                    style={{
                      ...option.style,
                      fontWeight: boldText ? 700 : 400,
                    }}
                  >
                    {option.label}
                  </span>
                  {active ? (
                    <Check aria-hidden="true" className="size-4 shrink-0 text-primary" />
                  ) : null}
                </button>
              );
            })}
          </div>
          <button
            type="button"
            aria-pressed={boldText}
            onClick={() => setBoldText(!boldText)}
            className={cn(
              "mt-2 flex min-h-10 w-full items-center gap-3 rounded-lg border px-3 py-2 text-left text-sm transition-colors",
              boldText
                ? "border-primary bg-accent text-accent-foreground"
                : "border-border bg-background text-muted-foreground hover:border-primary/45 hover:text-foreground",
            )}
          >
            <Bold
              aria-hidden="true"
              className="size-4 shrink-0 text-primary"
              strokeWidth={1.9}
            />
            <span className="min-w-0 flex-1 truncate text-sm font-semibold text-foreground">
              Bold Text
            </span>
            <span className="text-xs text-muted-foreground">
              {boldText ? "On" : "Off"}
            </span>
            {boldText ? (
              <Check aria-hidden="true" className="size-4 shrink-0 text-primary" />
            ) : null}
          </button>
        </div>
      </div>
    </section>
  );
}
