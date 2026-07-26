import { afterEach, expect, test } from "bun:test"
import { configuredOperatorDids, isConfiguredOperatorDid, operatorAccessConfigured } from "@/lib/operator-access"

const originalOperatorDids = process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS

afterEach(() => {
  if (originalOperatorDids === undefined) delete process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS
  else process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS = originalOperatorDids
})

test("allows only configured operator DIDs", () => {
  process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS = "did:plc:alice, did:plc:bob\ndid:web:operator.example"

  expect(configuredOperatorDids()).toEqual(new Set(["did:plc:alice", "did:plc:bob", "did:web:operator.example"]))
  expect(operatorAccessConfigured()).toBeTrue()
  expect(isConfiguredOperatorDid("did:plc:alice")).toBeTrue()
  expect(isConfiguredOperatorDid("did:plc:mallory")).toBeFalse()
})

test("denies access when no operator allowlist is configured", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS
  expect(operatorAccessConfigured()).toBeFalse()
  expect(isConfiguredOperatorDid("did:plc:alice")).toBeFalse()
})
