import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { toolsEnabled } from "@/lib/toolsEnabled";
import { config, proxy } from "@/proxy";

const env: Record<string, string | undefined> = process.env;
const keys = ["NEXT_PUBLIC_TOOLS_ENABLED", "NEXT_PUBLIC_APP_ENV", "APP_ENV", "NODE_ENV"] as const;
const original = Object.fromEntries(keys.map(key => [key, env[key]]));
afterEach(() => { for (const key of keys) { if (original[key] === undefined) delete env[key]; else env[key] = original[key]; } });

function environment(value: string) {
  delete process.env.NEXT_PUBLIC_TOOLS_ENABLED;
  delete process.env.APP_ENV;
  process.env.NEXT_PUBLIC_APP_ENV = value;
}

test("Tools defaults closed in Production and unknown environments, open only in known nonproduction environments", () => {
  for (const value of ["prod", "production", "preview-unknown"]) { environment(value); expect(toolsEnabled()).toBe(false); }
  for (const value of ["dev", "local", "test"]) { environment(value); expect(toolsEnabled()).toBe(true); }
  environment(""); env.NODE_ENV = "production";
  expect(toolsEnabled()).toBe(false);
});

test("an explicit deployment value overrides defaults and malformed values fail closed", () => {
  environment("dev");
  for (const value of ["false", "", "TRUE", "1"]) { process.env.NEXT_PUBLIC_TOOLS_ENABLED = value; expect(toolsEnabled()).toBe(false); }
  environment("prod"); process.env.NEXT_PUBLIC_TOOLS_ENABLED = "true";
  expect(toolsEnabled()).toBe(true);
});

test("server proxy covers all Tools trees and callbacks without intercepting Social, Podcasts or Reader", () => {
  const tools = ["articles", "live-post", "livestream", "brand-accounts", "content-calendar", "analytics", "scheduling"];
  const blocked = tools.flatMap(path => ["", "/", "/nested", "?_rsc=transition"].map(suffix => `/${path}${suffix}`));
  const allowed = ["/social", "/social/messages", "/podcasts", "/podcast-clips/one", "/read", "/me", "/articles-other"];
  // Next's testing package initializes server globals. Keep it out of the shared
  // DOM test process so later route tests retain their own async storage setup.
  // Next 16.2.6 still exports this helper under its Middleware name.
  const script = `
    const { unstable_doesMiddlewareMatch } = require("next/experimental/testing/server");
    const { config, paths } = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
    process.stdout.write(JSON.stringify(paths.map(path => unstable_doesMiddlewareMatch({ config, url: "https://thesocialwire.app" + path }))));
  `;
  const matches = JSON.parse(execFileSync(process.execPath, ["-e", script], {
    input: JSON.stringify({ config, paths: [...blocked, ...allowed] }), encoding: "utf8",
  }));
  expect(matches).toEqual([...blocked.map(() => true), ...allowed.map(() => false)]);
});

test("Production Tools requests return an uncached 404 while Development passes through", () => {
  environment("prod");
  const denied = proxy();
  expect(denied.status).toBe(404);
  expect(denied.headers.get("Cache-Control")).toBe("private, no-store");
  expect(denied.headers.get("x-middleware-next")).toBeNull();
  environment("dev");
  expect(proxy().headers.get("x-middleware-next")).toBe("1");
  process.env.NEXT_PUBLIC_TOOLS_ENABLED = "false";
  expect(proxy().status).toBe(404);
});
