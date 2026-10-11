import { expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const spec = Bun.YAML.parse(readFileSync(join(import.meta.dir, "../openapi.yaml"), "utf8")) as {
  paths: Record<string, Record<string, { security: unknown[]; responses: Record<string, unknown> }>>;
  components: { schemas: Record<string, { properties: Record<string, any>; required: string[] }> };
};
it("documents authenticated creator APIs with scoped nullable metrics and matching Bruno requests", () => {
  for (const [method, name, file] of [["get", "summary", "Get Creator Analytics"], ["post", "refresh", "Refresh Creator Analytics"], ["post", "events", "Record Creator Observation"]]) {
    const operation = spec.paths[`/v1/analytics/${name}`][method];
    expect(operation.security).toEqual([{ ATProtoOAuthDPoP: [] }]);
    expect(operation.responses["401"]).toBeDefined();
    for (const service of ["gateway", "appview"]) {
      const request = readFileSync(join(import.meta.dir, `../../../services/${service}/bruno/Analytics/${file}.bru`), "utf8");
      expect(request).toContain(`/v1/analytics/${name}`);
      expect(request).toContain("DPoP: {{dpopProof}}");
    }
  }
  const schemas = spec.components.schemas;
  expect(schemas.CreatorAnalyticsEvent.properties.event.enum).toEqual(["impression", "view", "outbound_click"]);
  expect(schemas.CreatorAnalyticsEvent.required).toEqual(["subjectUri", "event", "surface"]);
  expect(schemas.CreatorTracking.properties.ctr.type).toEqual(["number", "null"]);
  expect(schemas.CreatorEngagement.type).toEqual(["object", "null"]);
  expect(schemas.CreatorAnalyticsSummary.properties.coverage.properties.trackingScope.enum).toEqual(["social-wire"]);
  expect(schemas.CreatorAnalyticsSummary.properties.coverage.properties.platformImpressions.type).toBe("null");
});
