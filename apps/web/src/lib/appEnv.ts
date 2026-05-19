export type AppEnv = "prod" | "dev" | "local" | (string & {});

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
 */
export function getAppEnv(): AppEnv {
  const raw = readAppEnvRaw();
  if (raw) return normalizeAppEnv(raw);
  if (process.env.NODE_ENV === "development") return "local";
  if (process.env.VERCEL_ENV === "production") return "prod";
  return "dev";
}

export function shouldShowEnvironmentBanner(appEnv: AppEnv): boolean {
  return appEnv === "dev" || appEnv === "local";
}

export function environmentBannerHeight(appEnv: AppEnv): string {
  return shouldShowEnvironmentBanner(appEnv) ? "32px" : "0px";
}
