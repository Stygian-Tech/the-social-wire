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
const OPERATIONS_SOURCES = join(
  import.meta.dir,
  "../../../services/operations/Sources/Operations"
);
const OPERATIONS_ROUTES = join(OPERATIONS_SOURCES, "OperationsRoutes.swift");
const OPERATIONS_PROXY_ROUTES = join(
  GATEWAY_SOURCES,
  "Routes/OperationsProxyRoutes.swift"
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
      ...collectSwiftFiles(OPERATIONS_SOURCES),
    ]
      .map((file) => readFileSync(file, "utf8"))
      .join("\n");
    const paths = extractOpenAPIPaths(yaml);

    const routePatterns: Record<string, string[]> = {
      "/health": ['get("/health")'],
      "/livez": ['get("/livez")'],
      "/readyz": ['get("/readyz")'],
      "/freshness": ['get("/freshness")'],
      "/oauth-client-metadata.json": ['"/oauth-client-metadata.json"'],
      "/oauth/client-metadata.json": ['"/oauth/client-metadata.json"'],
      "/ios-client-metadata.json": ['"/ios-client-metadata.json"'],
      "/operations-oauth-client-metadata.json": ['"/operations-oauth-client-metadata.json"'],
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
      "/v1/operations/overview": ['"/v1/operations/overview"'],
      "/v1/operations/capabilities": ['"/v1/operations/capabilities"'],
      "/v1/operations/metrics": ['"/v1/operations/metrics"'],
      "/v1/operations/events/stream": ['"/v1/operations/events/stream"'],
      "/v1/operations/services": ['"/v1/operations/services"'],
      "/v1/operations/ingestion": ['"/v1/operations/ingestion"'],
      "/v1/operations/ingestion/endpoints": ['"/v1/operations/ingestion/endpoints"'],
      "/v1/operations/commands": ['"/v1/operations/commands"'],
      "/v1/operations/ingestion/reconnect": ['"/v1/operations/ingestion/reconnect"'],
      "/v1/operations/appview": ['"/v1/operations/appview"'],
      "/v1/operations/gaps": ['"/v1/operations/gaps"'],
      "/v1/operations/gaps/{id}": ['"/v1/operations/gaps/:id"'],
      "/v1/operations/gaps/{id}/investigation": ['"/v1/operations/gaps/:id/investigation"'],
      "/v1/operations/backfills/dry-run": ['"/v1/operations/backfills/dry-run"'],
      "/v1/operations/backfills": ['"/v1/operations/backfills"'],
      "/v1/operations/backfills/{id}": ['"/v1/operations/backfills/:id"'],
      "/v1/operations/backfills/{id}/pause": ['registerBackfillAction("pause"'],
      "/v1/operations/backfills/{id}/resume": ['registerBackfillAction("resume"'],
      "/v1/operations/backfills/{id}/cancel": ['registerBackfillAction("cancel"'],
      "/v1/operations/alerts": ['"/v1/operations/alerts"'],
      "/v1/operations/alerts/{id}/acknowledge": ['registerAlertAction("acknowledge"'],
      "/v1/operations/alerts/{id}/resolve": ['registerAlertAction("resolve"'],
      "/v1/operations/alerts/{id}/retry": ['for action in ["acknowledge", "resolve", "retry"]'],
      "/v1/operations/traces": ['"/v1/operations/traces"'],
      "/v1/operations/traces/{traceId}": ['"/v1/operations/traces/:traceId"'],
    };

    for (const path of paths) {
      const patterns = routePatterns[path];
      expect(patterns).toBeDefined();
      expect(patterns!.some((p) => routerSources.includes(p))).toBe(true);
    }
  });

  it("defines machine-readable Operations request, response, evidence, and concurrency contracts", () => {
    const yaml = readFileSync(OPENAPI_PATH, "utf8");
    const document = Bun.YAML.parse(yaml) as {
      paths: Record<string, Record<string, any>>;
      components: {
        schemas: Record<string, any>;
        parameters: Record<string, any>;
      };
    };

    const operationsPaths = Object.entries(document.paths).filter(([path]) =>
      path.startsWith("/v1/operations/")
    );
    expect(operationsPaths.length).toBeGreaterThan(10);

    for (const [path, pathItem] of operationsPaths) {
      for (const [method, operation] of Object.entries(pathItem)) {
        if (!['get', 'post', 'patch'].includes(method)) continue;
        expect(operation.operationId, `${method.toUpperCase()} ${path}`).toBeString();
        expect(operation.responses, `${method.toUpperCase()} ${path}`).toBeDefined();

        const success = operation.responses['200'] ?? operation.responses['201'] ?? operation.responses['202'];
        expect(success, `${method.toUpperCase()} ${path}`).toBeDefined();
        const content = success.content;
        if (path === "/v1/operations/events/stream") {
          expect(content?.['text/event-stream']?.schema?.type).toBe("string");
        } else {
          expect(content?.['application/json']?.schema, `${method.toUpperCase()} ${path}`).toBeDefined();
        }
      }
    }

    const schemas = document.components.schemas;
    expect(schemas.OperationsEvidenceMetadata.required).toEqual([
      "source",
      "accuracy",
      "generatedAt",
      "ageSeconds",
      "validUntil",
    ]);
    expect(schemas.OperationsEvidenceMetadata.properties.accuracy.enum).toEqual([
      "exact",
      "sampled",
      "estimated",
      "unavailable",
    ]);
    expect(schemas.BackfillJob.properties.sourceMode.enum).toContain("tap_verified_resync");
    expect(schemas.BackfillJob.required).toContain("authorResults");
    expect(schemas.BackfillJob.required).toContain("verificationStatus");
    expect(schemas.BackfillJob.required).toContain("scopeTruncated");
    expect(schemas.BackfillAuthorResult.properties.status.enum).toEqual([
      "succeeded",
      "partial",
      "failed",
      "cancelled",
      "unsupported",
    ]);
    expect(schemas.IngestionGap.properties.status.enum).toContain("verification_required");
    expect(schemas.OperationsEnvironment.enum).toEqual(["dev", "prod"]);
    expect(schemas.OperationsCapabilities.required).toContain("recoveryModes");
    expect(schemas.DatabaseObservabilitySnapshot.required).not.toContain("cacheHitRatio");
    expect(schemas.OperationsOverviewEvidence.required).toEqual(["services", "ingestion", "database"]);
    expect(schemas.OperationsOverview.properties.evidence.$ref)
      .toBe("#/components/schemas/OperationsOverviewEvidence");

    for (const schemaName of ["OperationsMutationRequest", "GapMutationRequest"]) {
      expect(schemas[schemaName].required).toContain("expectedVersion");
      expect(schemas[schemaName].required).toContain("idempotencyKey");
      expect(schemas[schemaName].required).not.toContain("auditNote");
    }
    expect(schemas.CreateBackfillRequest.required).toContain("requestFingerprint");

    expect(document.components.parameters.IdempotencyKey).toMatchObject({
      name: "Idempotency-Key",
      in: "header",
      required: true,
      schema: { type: "string", minLength: 1, maxLength: 128, pattern: "^\\S+$" },
    });

    const idempotentMutations: Array<[string, "post" | "patch"]> = [
      ["/v1/operations/ingestion/reconnect", "post"],
      ["/v1/operations/gaps/{id}", "patch"],
      ["/v1/operations/backfills", "post"],
      ["/v1/operations/backfills/{id}/pause", "post"],
      ["/v1/operations/backfills/{id}/resume", "post"],
      ["/v1/operations/backfills/{id}/cancel", "post"],
      ["/v1/operations/alerts/{id}/acknowledge", "post"],
      ["/v1/operations/alerts/{id}/resolve", "post"],
      ["/v1/operations/alerts/{id}/retry", "post"],
    ];
    for (const [path, method] of idempotentMutations) {
      expect(document.paths[path][method].parameters, `${method.toUpperCase()} ${path}`).toContainEqual({
        $ref: "#/components/parameters/IdempotencyKey",
      });
    }
    expect(document.paths["/v1/operations/backfills/{id}"].get.parameters).not.toContainEqual({
      $ref: "#/components/parameters/IdempotencyKey",
    });

    for (const path of [
      "/v1/operations/gaps/{id}",
      "/v1/operations/backfills/{id}/pause",
      "/v1/operations/backfills/{id}/resume",
      "/v1/operations/backfills/{id}/cancel",
      "/v1/operations/alerts/{id}/acknowledge",
      "/v1/operations/alerts/{id}/resolve",
      "/v1/operations/alerts/{id}/retry",
    ]) {
      const operation = document.paths[path]?.patch ?? document.paths[path]?.post;
      expect(operation.requestBody.content['application/json'].schema).toBeDefined();
      expect(operation.responses['409']).toBeDefined();
      expect(operation.responses['412']).toBeUndefined();
    }
  });

  it("uses named evidence-backed page wrappers and exact direct response shapes", () => {
    const document = Bun.YAML.parse(readFileSync(OPENAPI_PATH, "utf8")) as {
      paths: Record<string, Record<string, any>>;
      components: { schemas: Record<string, any> };
    };
    const schemas = document.components.schemas;
    const pages: Array<[string, string]> = [
      ["EndpointPage", "endpoints"],
      ["CommandPage", "commands"],
      ["GapPage", "gaps"],
      ["BackfillPage", "backfills"],
      ["AlertPage", "alerts"],
      ["TracePage", "traces"],
    ];
    for (const [schemaName, itemKey] of pages) {
      expect(schemas[schemaName].required, schemaName).toContain(itemKey);
      expect(schemas[schemaName].required, schemaName).toContain("evidence");
      expect(schemas[schemaName].properties[itemKey], schemaName).toBeDefined();
      expect(schemas[schemaName].properties.items, schemaName).toBeUndefined();
    }
    expect(schemas.TracePage.required).toContain("truncated");
    expect(schemas.OperationsServiceListResponse.required).toEqual(["services", "evidence"]);
    expect(schemas.OperationsIngestionResponse.required).toEqual(["sources", "evidence"]);
    expect(schemas.OperationsAppViewResponse.required).toEqual(["services", "evidence"]);

    expect(document.paths["/v1/operations/services"].get.responses["200"].content["application/json"].schema.$ref)
      .toBe("#/components/schemas/OperationsServiceListResponse");
    expect(document.paths["/v1/operations/ingestion"].get.responses["200"].content["application/json"].schema.$ref)
      .toBe("#/components/schemas/OperationsIngestionResponse");
    expect(document.paths["/v1/operations/appview"].get.responses["200"].content["application/json"].schema.$ref)
      .toBe("#/components/schemas/OperationsAppViewResponse");
  });

  it("documents implemented lifecycle views, query contracts, and non-default success statuses", () => {
    const document = Bun.YAML.parse(readFileSync(OPENAPI_PATH, "utf8")) as {
      paths: Record<string, Record<string, any>>;
    };
    const paths = document.paths;
    const parameter = (path: string, name: string) =>
      paths[path].get.parameters.find((candidate: any) => candidate.name === name);

    expect(parameter("/v1/operations/gaps", "view").schema.enum).toEqual(["active", "history", "all"]);
    expect(parameter("/v1/operations/backfills", "view").schema.enum).toEqual([
      "active",
      "needs_attention",
      "history",
      "all",
    ]);
    expect(parameter("/v1/operations/alerts", "view").schema.enum).toEqual(["active", "history", "all"]);
    expect(parameter("/v1/operations/metrics", "resolution").schema.const).toBe("1m");
    const lastEventId = paths["/v1/operations/events/stream"].get.parameters
      .find((candidate: any) => candidate.name === "Last-Event-ID");
    expect(lastEventId.in).toBe("header");
    expect(lastEventId.schema).toMatchObject({ type: "integer", format: "int64", minimum: 0 });
    expect(parameter("/v1/operations/traces", "traceId")).toBeUndefined();
    expect(parameter("/v1/operations/traces", "from")).toBeDefined();
    expect(parameter("/v1/operations/traces", "to")).toBeDefined();

    expect(paths["/v1/operations/backfills"].post.responses["201"]).toBeDefined();
    expect(paths["/v1/operations/ingestion/reconnect"].post.responses["202"]).toBeDefined();
    expect(paths["/v1/operations/alerts/{id}/retry"].post.responses["202"]).toBeDefined();
    expect(paths["/v1/operations/events/stream"].get.responses["410"]).toBeDefined();
    for (const path of [
      "/v1/operations/gaps/{id}",
      "/v1/operations/gaps/{id}/investigation",
      "/v1/operations/backfills/{id}",
      "/v1/operations/backfills/{id}/pause",
      "/v1/operations/backfills/{id}/resume",
      "/v1/operations/backfills/{id}/cancel",
      "/v1/operations/alerts/{id}/acknowledge",
      "/v1/operations/alerts/{id}/resolve",
      "/v1/operations/alerts/{id}/retry",
      "/v1/operations/traces/{traceId}",
    ]) {
      const operation = paths[path].get ?? paths[path].post ?? paths[path].patch;
      expect(operation.responses["404"], path).toBeDefined();
    }
  });

  it("keeps service statuses and Gateway pass-through behavior aligned", () => {
    const service = readFileSync(OPERATIONS_ROUTES, "utf8");
    const proxy = readFileSync(OPERATIONS_PROXY_ROUTES, "utf8");

    expect(service).toContain("EditedResponse(status: .created, response: job)");
    expect(service).toContain("EditedResponse(status: .accepted, response: command)");
    expect(service).toContain("EditedResponse(status: .accepted, response: alert)");
    expect(service).toContain("throw HTTPError(.gone");
    expect(service).toContain("throw HTTPError(.notFound");
    expect(proxy).toContain("return HTTPResponse.Status(code: code)");
    expect(proxy).toContain("status: Self.status(Int(reply.status.code))");
  });
});
