export type AppEnv = "prod" | "dev" | "local" | "test" | (string & {});

/** Read env label from `NEXT_PUBLIC_APP_ENV` (client) or server-only `APP_ENV`. */
export function readAppEnvRaw(): string {
  return (
    process.env.NEXT_PUBLIC_APP_ENV?.trim() ||
    process.env.APP_ENV?.trim() ||
    ""
  );
}

export function normalizeAppEnv(raw: string): AppEnv {
  const v = raw.trim().toLowerCase();
  if (v === "production") return "prod";
  return v as AppEnv;
}

/**
 * Resolved deployment label for banners and server layout.
 * Unset during `next dev` defaults to `local`; production builds default to `prod`.
 * Hosted non-production builds must set `APP_ENV=dev` explicitly.
 */
export function getAppEnv(): AppEnv {
  const raw = readAppEnvRaw();
  if (raw) return normalizeAppEnv(raw);
  if (process.env.NODE_ENV === "development") return "local";
  if (process.env.NODE_ENV === "production") return "prod";
  return "dev";
}

export function isNonProd(env: AppEnv): boolean {
  return env === "local" || env === "dev" || env === "test";
}

export function bannerMessage(env: AppEnv): string {
  switch (env) {
    case "local":
      return "Local Environment — Development Data and Relaxed Limits.";
    case "dev":
      return "Development Server — Not Production; Data May Be Reset.";
    case "test":
      return "Testing Server — Not Production; Data May Be Reset.";
    default:
      return "";
  }
}

const BANNER_CHROME =
  "supports-backdrop-filter:backdrop-blur-md border-b px-5 py-2.5 text-sm";

export function bannerClasses(env: AppEnv): string {
  switch (env) {
    case "local":
      return `${BANNER_CHROME} border-yellow-500/75 bg-yellow-400/40 font-medium text-yellow-950 shadow-sm supports-backdrop-filter:bg-yellow-400/28 dark:border-yellow-400/50 dark:bg-yellow-500/28 dark:text-yellow-50 dark:supports-backdrop-filter:bg-yellow-500/22`;
    case "dev":
    case "test":
      return `${BANNER_CHROME} border-red-500/70 bg-red-500/28 font-medium text-red-950 shadow-sm supports-backdrop-filter:bg-red-500/20 dark:border-red-400/45 dark:bg-red-500/24 dark:text-red-50 dark:supports-backdrop-filter:bg-red-500/20`;
    default:
      return BANNER_CHROME;
  }
}

/** Single-line bar: matches `py-2.5` + `text-sm` row in EnvironmentBanner (+ border-b). */
export const ENVIRONMENT_BANNER_OFFSET = "2.625rem" as const;

export function shouldShowEnvironmentBanner(appEnv: AppEnv): boolean {
  return isNonProd(appEnv);
}

export function environmentBannerHeight(appEnv: AppEnv): string {
  return shouldShowEnvironmentBanner(appEnv)
    ? ENVIRONMENT_BANNER_OFFSET
    : "0px";
}

/** Non-production UI affordances (record-kind badges, extra debug chrome). */
export function isDevDebugUiEnabled(): boolean {
  return shouldShowEnvironmentBanner(getAppEnv());
}
