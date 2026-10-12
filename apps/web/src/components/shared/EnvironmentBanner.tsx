import {
  bannerClasses,
  bannerMessage,
  shouldShowEnvironmentBanner,
} from "@/lib/appEnv";

type EnvironmentBannerProps = {
  appEnv: string;
};

/**
 * Environment banner — shown at the top of every page in non-production environments.
 *
 * `appEnv` is resolved on the server from `NEXT_PUBLIC_APP_ENV` / `APP_ENV` via `getAppEnv()`.
 */
export function EnvironmentBanner({ appEnv }: EnvironmentBannerProps) {
  if (!shouldShowEnvironmentBanner(appEnv)) return null;

  const body = bannerMessage(appEnv);
  if (!body) return null;

  return (
    <div
      role="status"
      aria-label={`${appEnv} environment`}
      className={bannerClasses(appEnv)}
    >
      <p className="font-medium">{body}</p>
    </div>
  );
}
