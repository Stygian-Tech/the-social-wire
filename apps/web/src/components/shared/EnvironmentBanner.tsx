"use client";

/**
 * Environment banner — shown at the top of every page in non-production environments.
 *
 * Controlled by NEXT_PUBLIC_APP_ENV:
 *   "prod"  → no banner
 *   "dev"   → amber banner
 *   "local" → blue banner (default when env var is unset)
 *
 * Reference: https://github.com/Stygian-Tech/my-context-protocol
 */

const env = process.env.NEXT_PUBLIC_APP_ENV ?? "local";

const BANNER_CONFIG = {
  dev: {
    label: "DEV",
    message: "You're on the development server",
    className:
      "bg-amber-400 text-amber-900 border-b border-amber-500",
  },
  local: {
    label: "LOCAL",
    message: "Running locally",
    className:
      "bg-blue-500 text-white border-b border-blue-600",
  },
} as const;

export function EnvironmentBanner() {
  if (env === "prod") return null;

  const config = BANNER_CONFIG[env as keyof typeof BANNER_CONFIG];
  if (!config) return null;

  return (
    <div
      role="banner"
      aria-label={`${config.label} environment`}
      className={`sticky top-0 z-50 flex items-center justify-center gap-2 px-4 py-1.5 text-xs font-medium ${config.className}`}
    >
      <span className="rounded bg-black/10 px-1.5 py-0.5 font-mono font-bold tracking-wider">
        {config.label}
      </span>
      <span>{config.message}</span>
    </div>
  );
}
