import { expect, test } from "bun:test"
import { parseAuthorDids } from "@/lib/pds-diagnostics"

test("normalizes deterministic unique DID scope and reports invalid entries", () => {
  expect(parseAuthorDids("did:plc:alice, did:web:example.com\ndid:plc:alice not-a-did")).toEqual({
    valid: ["did:plc:alice", "did:web:example.com"],
    invalid: ["not-a-did"],
  })
})
