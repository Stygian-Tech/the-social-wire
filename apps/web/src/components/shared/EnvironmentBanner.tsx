"use client";

import { useLayoutEffect, useRef } from "react";
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
  const banner = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const element = banner.current;
    if (!element) return;
    const body = document.body;
    const previous = body.style.getPropertyValue("--environment-banner-height");
    const measure = () => body.style.setProperty("--environment-banner-height", `${element.getBoundingClientRect().height}px`);
    measure();
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(measure);
    observer?.observe(element);
    window.addEventListener("resize", measure);
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", measure);
      if (previous) body.style.setProperty("--environment-banner-height", previous);
      else body.style.removeProperty("--environment-banner-height");
    };
  }, [appEnv]);
  if (!shouldShowEnvironmentBanner(appEnv)) return null;

  const body = bannerMessage(appEnv);
  if (!body) return null;

  return (
    <div
      ref={banner}
      role="status"
      aria-label={`${appEnv} environment`}
      className={`${bannerClasses(appEnv)} min-h-[2.625rem]`}
    >
      <p className="font-medium">{body}</p>
    </div>
  );
}
