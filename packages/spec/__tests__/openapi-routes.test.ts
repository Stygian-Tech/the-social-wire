import { describe, expect, it } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const OPENAPI_PATH = join(import.meta.dir, "../openapi.yaml");
const API_SOURCES = join(
  import.meta.dir,
  "../../../services/api/Sources/App"
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
  it("documents paths registered in the API router sources", () => {
    const yaml = readFileSync(OPENAPI_PATH, "utf8");
    const routerSources = collectSwiftFiles(API_SOURCES)
      .map((file) => readFileSync(file, "utf8"))
      .join("\n");
    const paths = extractOpenAPIPaths(yaml);

    const routePatterns: Record<string, string[]> = {
      "/health": ['get("/health")'],
      "/oauth/client-metadata.json": ['"/oauth/client-metadata.json"'],
      "/ios-client-metadata.json": ['"/ios-client-metadata.json"'],
      "/v1/sync/preferences": ['"/v1/sync/preferences"'],
      "/v1/pds/cache/record": ['"/v1/pds/cache/record"'],
      "/v1/appview/entries": ['"/v1/appview/entries"'],
      "/v1/appview/read-marks": ['"/v1/appview/read-marks"'],
      "/v1/appview/enroll": ['"/v1/appview/enroll"'],
      "/v1/appview/privacy/purge": ['"/v1/appview/privacy/purge"'],
      "/discovery/refresh": ['"/discovery/refresh"'],
      "/discovery/{userDid}": ['"/discovery/:userDid"'],
      "/publications/{pubId}/entries": ['"/publications/:pubId/entries"'],
      "/entries/{entryId}": ['"/entries/:entryId"'],
    };

    for (const path of paths) {
      const patterns = routePatterns[path];
      expect(patterns).toBeDefined();
      expect(patterns!.some((p) => routerSources.includes(p))).toBe(true);
    }
  });
});
