import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../../..");
const read = (path: string) => readFileSync(join(root, path), "utf8");

test("Media projection contract stays authenticated, bounded, stateless and duration-honest", () => {
  const document = Bun.YAML.parse(read("packages/spec/openapi.yaml")) as {
    paths: Record<string, { post: { description: string; requestBody: { content: Record<string, { schema: { properties: { posts: { maxItems: number } } } }> }; responses: Record<string, unknown> } }>;
  };
  const route = document.paths["/v1/media/project"]!.post;
  expect(route.requestBody.content["application/json"]!.schema.properties.posts.maxItems).toBe(30);
  expect(route.responses["401"]).toBeDefined();
  expect(route.description).toContain("duration is unavailable");
  expect(route.description).toContain("retain its upstream cursor");
  expect(read("services/gateway/internal/gateway/routes.go")).toContain('{Method: "POST", Path: "/v1/media/project", Target: "/v1/media/project", UpstreamMethod: "POST", Service: "appview"}');
  expect(read("services/appview/internal/runtime/host.go")).toContain("media.Routes{}.Register(protectedMux)");
  for (const service of ["appview", "gateway"]) {
    const bruno = read(`services/${service}/bruno/Media/Project Media.bru`);
    expect(bruno).toContain("/v1/media/project");
    expect(bruno).toContain("DPoP: {{dpopProof}}");
    expect(bruno).toContain('"posts":[]');
  }
});
