"use client";

/**
 * Environment banner — shown at the top of every page in non-production environments.
 *
 * `appEnv` is resolved on the server from `NEXT_PUBLIC_APP_ENV` / `APP_ENV` via `getAppEnv()`.
 */

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

type EnvironmentBannerProps = {
  appEnv: string;
};

export function EnvironmentBanner({ appEnv }: EnvironmentBannerProps) {
  const config = BANNER_CONFIG[appEnv as keyof typeof BANNER_CONFIG];
  if (!config) return null;

  return (
    <div
      role="banner"
      aria-label={`${config.label} environment`}
      className={`relative z-50 flex h-[var(--environment-banner-height)] shrink-0 items-center justify-center gap-2 px-4 text-xs font-medium ${config.className}`}
    >
      <span className="rounded bg-black/10 px-1.5 py-0.5 font-mono font-bold tracking-wider">
        {config.label}
      </span>
      <span>{config.message}</span>
    </div>
  );
}
