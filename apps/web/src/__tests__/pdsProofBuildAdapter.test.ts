import { expect, test } from "bun:test";
import path from "node:path";
import adapt from "../../scripts/pds-proof-browser-dependencies.cjs";
const installed = (packageName: string, file: string) => path.join(path.dirname(new URL(import.meta.resolve(packageName)).pathname), file);

test("browser adapter verifies the exact installed upstream patterns and preserves verifier logic", async () => {
  const files = [installed("@atproto/common", "index.js"), installed("@atproto/common", "logger.js"), installed("@atproto/repo", "car.js")];
  for (const resourcePath of files) {
    const source = await Bun.file(resourcePath).text();
    const output = adapt.call({ resourcePath }, source);
    expect(output).not.toBe(source);
    if (resourcePath.endsWith("/index.js")) {
      expect(output).toContain("export * from './logger.js'");
      expect(output).not.toContain("export * from './streams.js'");
      expect(() => adapt.call({ resourcePath }, source.replace("export * from './fs.js';", ""))).toThrow("dependency changed");
    } else if (resourcePath.endsWith("/logger.js")) {
      expect(output).not.toContain("process.env.LOG_");
      expect(() => adapt.call({ resourcePath }, source.replace("process.env.LOG_ENABLED", "process.env.NEW_LOG_ENABLED"))).toThrow("dependency changed");
    } else {
      expect(output).toContain("pdsProofTimer.ts");
      expect(output.replace(/from "[^"]*pdsProofTimer\.ts"/, "from 'node:timers/promises'")).toBe(source);
      expect(() => adapt.call({ resourcePath }, source.replace("node:timers/promises", "node:timers"))).toThrow("dependency changed");
    }
  }
  expect(() => adapt.call({ resourcePath: "/some/other/package.js" }, "")).toThrow("Unreviewed");
});
