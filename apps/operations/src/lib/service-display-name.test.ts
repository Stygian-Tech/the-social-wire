import { expect, test } from "bun:test"
import { serviceDisplayName } from "@/lib/service-display-name"

test("presents the stable appview-worker service identity as Charybdis", () => {
  expect(serviceDisplayName("appview-worker")).toBe("Charybdis")
  expect(serviceDisplayName("gateway")).toBe("gateway")
})
