import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const root = join(import.meta.dir, "../../..");
const spec = Bun.YAML.parse(readFileSync(join(root, "packages/spec/openapi.yaml"), "utf8")) as any;
const prefix = "/xrpc/app.thesocialwire.socialDraft.";

test("private attachment HTTP routes retain binary headers and authenticated ownership", () => {
  const paths = Object.keys(spec.paths).filter((path) => path.startsWith(prefix));
  expect(paths).toHaveLength(6);
  for (const path of paths) {
    const operation = Object.values(spec.paths[path])[0] as any;
    expect(operation.security).toEqual([{ ATProtoOAuthDPoP: [] }]);
    expect(operation.responses["503"].description).toBe("Unavailable");
    expect(operation.responses["200"].headers["Cache-Control"].schema.const).toBe("private, no-store");
  }
  const upload = spec.paths[prefix + "uploadAttachment"].post;
  expect(Object.keys(upload.requestBody.content)).toEqual(["application/octet-stream"]);
  expect(upload.parameters.find((param: any) => param.name === "X-Social-Draft-Upload-Id").required).toBe(true);
  const length = upload.parameters.find((param: any) => param.name === "Content-Length");
  expect(length.required).toBe(true);
  expect(length.schema).toEqual({ type: "integer", minimum: 1, maximum: 104857600 });
  expect(upload.responses["411"]).toBeDefined();
  expect(Object.keys(spec.paths[prefix + "getAttachment"].get.responses["200"].content)).toEqual(["*/*"]);
  for (const service of ["gateway", "appview"]) {
    const bruno = readFileSync(join(root, `services/${service}/bruno/XRPC/app.thesocialwire.socialDraft.uploadAttachment.bru`), "utf8");
    expect(bruno).toContain("body: file");
    expect(bruno).toContain("X-Social-Draft-Upload-Id:");
    expect(bruno).toContain("Content-Length:");
    expect(bruno).toContain("DPoP:");
  }
});
