import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
const root = join(import.meta.dir, "../../..");
const spec = Bun.YAML.parse(readFileSync(join(root, "packages/spec/openapi.yaml"), "utf8")) as any;
const prefix = "/xrpc/app.thesocialwire.socialDraft.";

test("manifest limits fit 100 native posts with four original and prepared photos", () => {
  expect(spec.components.schemas.SocialDraftManifest.properties.attachments.maxItems).toBe(800);
  const input = spec.paths[prefix + "putManifest"].post.requestBody.content["application/json"].schema.$ref.split("/").at(-1);
  expect(spec.components.schemas[input].properties.attachments.maxItems).toBe(800);
});

test("private attachment HTTP routes retain binary headers and authenticated ownership", () => {
  const paths = Object.keys(spec.paths).filter((path) => path.startsWith(prefix));
  expect(paths).toHaveLength(7);
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


test("catalog GIF copies are Gateway-only binary queries with no URL input", () => {
  const operation = spec.paths[prefix + "getGifFile"].get;
  expect(operation.parameters.map((param: any) => param.name)).toEqual(["id", "rendition"]);
  expect(operation.parameters.every((param: any) => param.required)).toBe(true);
  expect(operation.parameters[1].schema.enum).toEqual(["gif", "poster", "mp4", "webm"]);
  expect(operation.responses["200"].content["image/gif"].schema.maxLength).toBe(104857600);
  expect(operation.responses["200"].content["image/png"].schema.maxLength).toBe(1000000);
  expect(operation.description).toContain("Not implemented by AppView");
  const gateway = readFileSync(join(root, "services/gateway/bruno/XRPC/app.thesocialwire.socialDraft.getGifFile.bru"), "utf8");
  expect(gateway).toContain("rendition={{gifRendition}}");
  expect(gateway).toContain("DPoP:");
  // This is a Gateway-owned file-copy surface; deliberately absent from AppView.
  expect(existsSync(join(root, "services/appview/bruno/XRPC/app.thesocialwire.socialDraft.getGifFile.bru"))).toBe(false);
});


test("retired reservations expose a typed 409 without changing manifest CAS", () => {
  const conflict = spec.paths[prefix + "reserveAttachment"].post.responses["409"];
  expect(conflict.content["application/json"].schema.properties.error.enum).toEqual(["Conflict", "UploadPending", "AssetRetired"]);
  expect(conflict.description).toContain("ordinary Conflict does not indicate retirement");
  expect(spec.paths[prefix + "putManifest"].post.responses["409"].description).not.toContain("AssetRetired");
});
