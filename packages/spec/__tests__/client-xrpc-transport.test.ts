import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { extname, join } from "node:path";

const REPO_ROOT = join(import.meta.dir, "../../..");
const manifest = JSON.parse(
  readFileSync(join(REPO_ROOT, "packages/spec/endpoint-manifest.json"), "utf8")
) as {
  entries: Array<{
    method: string;
    path: string;
    classification: string;
    xrpcNsid?: string;
  }>;
};

const clientMigrations = manifest.entries.filter(
  (entry) =>
    entry.classification === "xrpc-migration" &&
    entry.xrpcNsid != null &&
    /app\.thesocialwire\.(appview|publication|sync)\./.test(entry.xrpcNsid)
);
const compatibilityMigrations = clientMigrations.filter(({ path }) => path.startsWith("/v1/"));

function collectSourceFiles(root: string, extensions: Set<string>): string[] {
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      if (["__tests__", "Tests", ".build"].includes(entry.name)) return [];
      return collectSourceFiles(path, extensions);
    }
    return extensions.has(extname(entry.name)) ? [path] : [];
  });
}

describe("client XRPC transport", () => {
  const webSources = collectSourceFiles(
    join(REPO_ROOT, "apps/web/src"),
    new Set([".ts", ".tsx"])
  );
  const appleSources = collectSourceFiles(
    join(REPO_ROOT, "apps/apple/SocialWire"),
    new Set([".swift"])
  );

  it("keeps eligible REST compatibility paths out of production client sources", () => {
    const sources = [...webSources, ...appleSources].map((path) => ({
      path,
      contents: readFileSync(path, "utf8"),
    }));

    for (const migration of compatibilityMigrations) {
      const offenders = sources
        .filter((source) => source.contents.includes(migration.path))
        .map((source) => source.path.replace(`${REPO_ROOT}/`, ""));
      expect(offenders, `${migration.path} should use ${migration.xrpcNsid}`).toEqual([]);
    }
  });

  it("writes user-owned publication records through standard PDS XRPC", () => {
    const sources = [...webSources, ...appleSources].map((path) => ({
      path,
      contents: readFileSync(path, "utf8"),
    }));
    const gatewayWritePaths = [
      "/v1/publications/folders",
      "/v1/publications/prefs",
      "/v1/publications/subscriptions",
      "/v1/publications/rss-subscriptions",
    ];

    for (const path of gatewayWritePaths) {
      const offenders = sources
        .filter((source) => source.contents.includes(path))
        .map((source) => source.path.replace(`${REPO_ROOT}/`, ""));
      expect(offenders, `${path} should use com.atproto.repo.* directly`).toEqual([]);
    }

    const applePds = readFileSync(
      join(REPO_ROOT, "apps/apple/SocialWire/Services/PDSRecordService.swift"),
      "utf8"
    );
    expect(applePds).toContain("xrpc.createRecord");
    expect(applePds).toContain("xrpc.putRecord");
    expect(applePds).toContain("xrpc.deleteRecord");
  });

  it("keeps web and Apple XRPC method catalogs aligned with every client migration", () => {
    const webCatalog = readFileSync(
      join(REPO_ROOT, "apps/web/src/lib/socialWireXrpc.ts"),
      "utf8"
    );
    const appleCatalog = readFileSync(
      join(
        REPO_ROOT,
        "apps/apple/SocialWire/Services/Gateway/SocialWireXRPCMethod.swift"
      ),
      "utf8"
    );

    for (const { xrpcNsid } of clientMigrations) {
      expect(webCatalog, `web catalog missing ${xrpcNsid}`).toContain(xrpcNsid!);
      expect(appleCatalog, `Apple catalog missing ${xrpcNsid}`).toContain(xrpcNsid!);
    }
  });

  it("forwards Gateway REST adapters to AppView XRPC upstream", () => {
    const source = readFileSync(
      join(
        REPO_ROOT,
        "services/gateway/Sources/Gateway/Routes/AppViewProxyRoutes.swift"
      ),
      "utf8"
    );
    const proxyMigrations = clientMigrations.filter(
      ({ xrpcNsid }) =>
        xrpcNsid!.startsWith("app.thesocialwire.appview.") ||
        xrpcNsid!.startsWith("app.thesocialwire.publication.")
    );

    for (const migration of proxyMigrations) {
      const routeMethod = migration.method.toLowerCase();
      const routeStart = source.indexOf(
        `group.${routeMethod}("${migration.path}")`
      );
      expect(routeStart, `missing Gateway adapter for ${migration.path}`).toBeGreaterThanOrEqual(0);
      const routeEnd = source.indexOf("\n    }", routeStart);
      expect(routeEnd, `unterminated Gateway adapter for ${migration.path}`).toBeGreaterThan(routeStart);
      const handler = source.slice(routeStart, routeEnd);
      expect(handler, `${migration.path} must forward to XRPC`).toContain(
        `path: "/xrpc/${migration.xrpcNsid}"`
      );
      expect(handler, `${migration.path} must use the Lexicon HTTP verb`).toContain(
        `method: "${/\.(get|list)[A-Z]/.test(migration.xrpcNsid!) ? "GET" : "POST"}`
      );
    }
  });

  it("classifies canonical XRPC feed routes in request telemetry", () => {
    const middleware = readFileSync(
      join(
        REPO_ROOT,
        "packages/swift/GatewayCore/Sources/GatewayCore/Middleware/RequestTraceMiddleware.swift"
      ),
      "utf8"
    );
    expect(middleware).toContain(
      '"/xrpc/app.thesocialwire.appview.getFeed"'
    );
    expect(middleware).toContain(
      '"/xrpc/app.thesocialwire.appview.listEntries"'
    );
  });

  it("uses canonical repeated query parameters for XRPC arrays", () => {
    const webClient = readFileSync(
      join(REPO_ROOT, "apps/web/src/lib/thinAppViewClient.ts"),
      "utf8"
    );
    const appleClient = readFileSync(
      join(
        REPO_ROOT,
        "apps/apple/SocialWire/Services/Gateway/SocialWireGatewayClient.swift"
      ),
      "utf8"
    );
    const appViewRoutes = readFileSync(
      join(
        REPO_ROOT,
        "services/appview/Sources/AppView/Routes/AppViewExtendedRoutes.swift"
      ),
      "utf8"
    );

    expect(webClient).toContain('params.append("publicationIds", publicationId)');
    expect(appleClient).toContain(
      'repeatedQuery: ["publicationIds": publicationIds]'
    );
    expect(appViewRoutes).toContain(
      'queryParameters[values: "publicationIds"]'
    );
  });

  it("sends JSON objects for empty-input XRPC procedures", () => {
    const webPublicationClient = readFileSync(
      join(REPO_ROOT, "apps/web/src/lib/publicationProjectionClient.ts"),
      "utf8"
    );
    const webAppViewClient = readFileSync(
      join(REPO_ROOT, "apps/web/src/lib/thinAppViewClient.ts"),
      "utf8"
    );
    const appleClient = readFileSync(
      join(
        REPO_ROOT,
        "apps/apple/SocialWire/Services/Gateway/SocialWireGatewayClient.swift"
      ),
      "utf8"
    );

    expect(webPublicationClient).toContain('body: "{}"');
    expect(webAppViewClient).toContain('body: "{}"');
    expect(appleClient.match(/JSONEncoder\(\)\.encode\(EmptyXRPCInput\(\)\)/g)).toHaveLength(2);
  });

  it("keeps AppView, Gateway, and Charybdis Bruno clients XRPC-first", () => {
    const brunoSources = ["gateway", "appview", "appview-worker"].flatMap(
      (service) =>
        collectSourceFiles(
          join(REPO_ROOT, `services/${service}/bruno`),
          new Set([".bru"])
        )
    );
    const forbiddenPaths = [
      ...compatibilityMigrations.map(({ path }) => path),
      "/v1/publications/folders",
      "/v1/publications/prefs",
      "/v1/publications/subscriptions",
      "/v1/publications/rss-subscriptions",
    ];

    for (const path of forbiddenPaths) {
      const offenders = brunoSources
        .filter((source) => readFileSync(source, "utf8").includes(path))
        .map((source) => source.replace(`${REPO_ROOT}/`, ""));
      expect(offenders, `${path} must remain compatibility-only`).toEqual([]);
    }
  });
});
