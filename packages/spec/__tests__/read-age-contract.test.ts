import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../../..");
const document = Bun.YAML.parse(readFileSync(join(root, "packages/spec/openapi.yaml"), "utf8")) as {
  paths: Record<string, Record<string, any>>;
};

describe("calendar-day feed read contracts", () => {
  it("documents explicit time-zone queries and required cutoff mutations", () => {
    const query = document.paths["/xrpc/app.thesocialwire.appview.getReadAgeOptions"].get;
    expect(query.parameters.find((parameter: any) => parameter.name === "timeZone").required).toBe(true);
    const output = query.responses["200"].content["application/json"].schema;
    expect(output.required).toEqual(["referenceDay", "options"]);
    expect(output.properties.options.items.required).toEqual(["days", "before", "count"]);
    expect(output.properties.options.items.properties.days.minimum).toBe(1);

    const mutation = document.paths["/xrpc/app.thesocialwire.appview.markReadBefore"].post;
    expect(mutation.requestBody.content["application/json"].schema.required).toEqual(["scope", "before"]);
    const result = mutation.responses["200"].content["application/json"].schema;
    expect(result.required).toEqual(["marked", "entryIds", "readAt", "unreadCounts"]);
    expect(result.properties.unreadCounts.additionalProperties).toEqual({ type: "integer", minimum: 0 });
    expect(result.properties.unreadCounts.description).toContain("Missing publication keys mean unknown");
    expect(query.responses["404"]).toBeDefined();
    expect(mutation.responses["404"]).toBeDefined();
  });

  it("keeps age-based calls separate from the existing mark-all contract", () => {
    const existing = document.paths["/v1/appview/mark-all-read"].post.requestBody.content["application/json"].schema;
    expect(existing.required).toEqual(["scope"]);
    expect(existing.properties.before).toBeUndefined();
    const gateway = readFileSync(join(root, "services/gateway/Sources/Gateway/Routes/AppViewProxyRoutes.swift"), "utf8");
    for (const [name, method] of [["getReadAgeOptions", "get"], ["markReadBefore", "post"]]) {
      const path = `/xrpc/app.thesocialwire.appview.${name}`;
      expect(gateway).toContain(`group.${method}("${path}")`);
      expect(gateway).toContain(`path: "${path}"`);
      for (const service of ["gateway", "appview"]) {
        const bruno = readFileSync(join(root, `services/${service}/bruno/XRPC/app.thesocialwire.appview.${name}.bru`), "utf8");
        expect(bruno).toContain(`${method} {`);
        expect(bruno).toContain(path);
        expect(bruno).toContain("DPoP: {{dpopProof}}");
      }
    }
  });
});
