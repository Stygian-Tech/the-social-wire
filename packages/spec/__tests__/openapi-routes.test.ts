import { describe, expect, it } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const OPENAPI_PATH = join(import.meta.dir, "../openapi.yaml");
const GATEWAY_SOURCES = join(
  import.meta.dir,
  "../../../services/gateway/Sources/Gateway"
);
const GATEWAY_CORE_SOURCES = join(
  import.meta.dir,
  "../../../packages/swift/GatewayCore/Sources/GatewayCore"
);
const APPVIEW_SOURCES = join(
  import.meta.dir,
  "../../../services/appview/Sources/AppView"
);

function collectSwiftFiles(dir: string): string[] {
  const entries = readdirSync(dir, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectSwiftFiles(full));
    } else if (entry.name.endsWith(".swift")) {
      files.push(full);
    }
  }
  return files;
}

function extractOpenAPIPaths(yaml: string): string[] {
  const paths: string[] = [];
  for (const line of yaml.split("\n")) {
    const match = line.match(/^  (\/[^\s:]+):/);
    if (match) paths.push(match[1]!);
  }
  return paths;
}

describe("OpenAPI route drift", () => {
  it("documents paths registered in gateway and appview router sources", () => {
    const yaml = readFileSync(OPENAPI_PATH, "utf8");
    const routerSources = [
      ...collectSwiftFiles(GATEWAY_SOURCES),
      ...collectSwiftFiles(GATEWAY_CORE_SOURCES),
      ...collectSwiftFiles(APPVIEW_SOURCES),
    ]
      .map((file) => readFileSync(file, "utf8"))
      .join("\n");
    const paths = extractOpenAPIPaths(yaml);

    const routePatterns: Record<string, string[]> = {
      "/health": ['get("/health")'],
      "/oauth/client-metadata.json": ['"/oauth/client-metadata.json"'],
      "/ios-client-metadata.json": ['"/ios-client-metadata.json"'],
      "/v1/sync/preferences": ['"/v1/sync/preferences"'],
      "/v1/pds/cache/record": ['"/v1/pds/cache/record"'],
      "/v1/publications/sidebar": ['"/v1/publications/sidebar"'],
      "/v1/publications/refresh": ['"/v1/publications/refresh"'],
      "/v1/publications/resolve": ['"/v1/publications/resolve"'],
      "/v1/publications/folders": ['post("/v1/publications/folders"'],
      "/v1/publications/folders/{rkey}": [
        '"/v1/publications/folders/:rkey"',
        'put("/v1/publications/folders/:rkey")',
        'delete("/v1/publications/folders/:rkey")',
      ],
      "/v1/publications/prefs": ['"/v1/publications/prefs"'],
      "/v1/publications/subscriptions": ['"/v1/publications/subscriptions"'],
      "/v1/publications/rss-subscriptions": ['"/v1/publications/rss-subscriptions"'],
      "/v1/reader/read-marks": ['"/v1/reader/read-marks"'],
      "/v1/reader/mark-all-read": ['"/v1/reader/mark-all-read"'],
      "/v1/appview/entries": ['"/v1/appview/entries"'],
      "/v1/appview/entry": ['"/v1/appview/entry"'],
      "/v1/appview/unread-counts": ['"/v1/appview/unread-counts"'],
      "/v1/appview/bootstrap-stream": ['"/v1/appview/bootstrap-stream"'],
      "/v1/appview/read-marks": ['"/v1/appview/read-marks"'],
      "/v1/appview/enroll": ['"/v1/appview/enroll"'],
      "/v1/appview/privacy/purge": ['"/v1/appview/privacy/purge"'],
      "/v1/appview/mark-all-read": ['"/v1/appview/mark-all-read"'],
      "/v1/latr/saves": ['"/v1/latr/saves"'],
      "/v1/latr/saves/{rkey}/state": ['"/v1/latr/saves/:rkey/state"'],
      "/v1/latr/saves/{rkey}": ['"/v1/latr/saves/:rkey"'],
      "/v1/latr/og-preview": ['"/v1/latr/og-preview"'],
    };

    for (const path of paths) {
      const patterns = routePatterns[path];
      expect(patterns).toBeDefined();
      expect(patterns!.some((p) => routerSources.includes(p))).toBe(true);
    }
  });
});
