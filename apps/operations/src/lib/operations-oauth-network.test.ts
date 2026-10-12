import { expect, test } from "bun:test"
import { operationsOAuthNetwork } from "./operations-oauth-network"

test("loopback OAuth uses only explicitly configured sandbox discovery endpoints", () => {
  expect(operationsOAuthNetwork("127.0.0.1", { handleResolver: "https://appview.atmosbox.test", plcDirectory: "https://plc.atmosbox.test" })).toEqual({ handleResolver: "https://appview.atmosbox.test", plcDirectoryUrl: "https://plc.atmosbox.test" })
  expect(operationsOAuthNetwork("localhost").plcDirectoryUrl).toBe("https://plc.directory")
})
test("hosted Operations always ignores sandbox discovery overrides", () => {
  expect(operationsOAuthNetwork("ops.testing.thesocialwire.app", { handleResolver: "http://unsafe.test/path", plcDirectory: "bad" })).toEqual({ handleResolver: "https://bsky.social", plcDirectoryUrl: "https://plc.directory" })
})
test("loopback discovery rejects non-origin URLs and plaintext endpoints", () => {
  for (const url of ["http://appview.test", "https://user:password@appview.test", "https://appview.test/path", "https://appview.test/?token=private", "https://appview.test/#fragment"])
    expect(() => operationsOAuthNetwork("127.0.0.1", { handleResolver: url })).toThrow("HTTPS Origins")
})
