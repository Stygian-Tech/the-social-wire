import { afterEach, describe, expect, it } from "bun:test";

import {
  environmentBannerHeight,
  getAppEnv,
  normalizeAppEnv,
  shouldShowEnvironmentBanner,
} from "@/lib/appEnv";

const saved = {
  NEXT_PUBLIC_APP_ENV: process.env.NEXT_PUBLIC_APP_ENV,
  APP_ENV: process.env.APP_ENV,
  NODE_ENV: process.env.NODE_ENV,
  VERCEL_ENV: process.env.VERCEL_ENV,
};

afterEach(() => {
  process.env.NEXT_PUBLIC_APP_ENV = saved.NEXT_PUBLIC_APP_ENV;
  process.env.APP_ENV = saved.APP_ENV;
  process.env.NODE_ENV = saved.NODE_ENV;
  process.env.VERCEL_ENV = saved.VERCEL_ENV;
});

describe("getAppEnv", () => {
  it("prefers NEXT_PUBLIC_APP_ENV", () => {
    process.env.NEXT_PUBLIC_APP_ENV = "dev";
    process.env.APP_ENV = "local";
    expect(getAppEnv()).toBe("dev");
  });

  it("falls back to APP_ENV on the server", () => {
    delete process.env.NEXT_PUBLIC_APP_ENV;
    process.env.APP_ENV = "dev";
    expect(getAppEnv()).toBe("dev");
  });

  it("defaults to local in development when unset", () => {
    delete process.env.NEXT_PUBLIC_APP_ENV;
    delete process.env.APP_ENV;
    process.env.NODE_ENV = "development";
    expect(getAppEnv()).toBe("local");
  });
});

describe("normalizeAppEnv", () => {
  it("maps production alias to prod", () => {
    expect(normalizeAppEnv("production")).toBe("prod");
  });
});

describe("environment banner", () => {
  it("shows dev and local banners only", () => {
    expect(shouldShowEnvironmentBanner("dev")).toBe(true);
    expect(shouldShowEnvironmentBanner("local")).toBe(true);
    expect(shouldShowEnvironmentBanner("prod")).toBe(false);
    expect(environmentBannerHeight("prod")).toBe("0px");
    expect(environmentBannerHeight("dev")).toBe("32px");
  });
});
