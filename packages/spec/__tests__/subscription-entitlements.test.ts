import { expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const spec = Bun.YAML.parse(readFileSync(join(import.meta.dir, "../openapi.yaml"), "utf8")) as {
  paths: Record<string, Record<string, any>>;
};

it("documents authenticated server-owned plans and paid creator reads without blocking observation ingestion", () => {
  const operation = spec.paths["/v1/subscription/entitlements"].get;
  expect(operation.security).toEqual([{ ATProtoOAuthDPoP: [] }]);
  expect(operation.responses["401"]).toBeDefined();
  expect(operation.responses["200"].headers["Cache-Control"].schema.const).toBe("private, no-store");
  const schema = operation.responses["200"].content["application/json"].schema;
  expect(schema.required).toEqual(["viewerDid", "plan"]);
  expect(schema.properties.plan.enum).toEqual(["free", "pro"]);
  expect(operation.description).toContain("SOCIALWIRE_PRO_DIDS");
  expect(spec.paths["/v1/analytics/summary"].get.responses["403"]).toBeDefined();
  expect(spec.paths["/v1/analytics/refresh"].post.responses["403"]).toBeDefined();
  expect(spec.paths["/v1/analytics/events"].post.responses["403"]).toBeUndefined();
  const request = readFileSync(join(import.meta.dir, "../../../services/gateway/bruno/Subscription/Get Subscription Entitlements.bru"), "utf8");
  expect(request).toContain("{{baseUrl}}/v1/subscription/entitlements");
  expect(request).toContain("DPoP: {{dpopProof}}");
});
