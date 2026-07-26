import { afterEach, expect, test } from "bun:test"
import { act, cleanup, render, screen } from "@testing-library/react"
import { TokenRefreshError, type OAuthSession } from "@atproto/oauth-client-browser"
import { OperatorSignIn } from "@/components/operations/sign-in"
import { authFetch } from "@/lib/auth"
import { OperationsAuthProvider } from "@/lib/auth-context"

const originalDemoMode = process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
const originalOperatorDids = process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS

afterEach(() => {
  cleanup()
  if (originalDemoMode === undefined) delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  else process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = originalDemoMode
  if (originalOperatorDids === undefined) delete process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS
  else process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS = originalOperatorDids
})

test("stops using an invalidated session and asks the operator to sign in again", async () => {
  process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = "1"
  process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS = "did:plc:operator"
  const did = "did:plc:operator"
  const session = {
    did,
    fetchHandler: async () => {
      throw new TokenRefreshError(did, "The session was revoked")
    },
  } as unknown as OAuthSession

  render(
    <OperationsAuthProvider>
      <OperatorSignIn />
    </OperationsAuthProvider>,
  )

  await act(async () => {
    await authFetch(session, "https://api.testing.thesocialwire.app/v1/operations/overview").catch(() => undefined)
  })

  expect(screen.getByRole("alert").textContent).toContain(
    "Your operator session expired. Sign in again to resume live operations data.",
  )
})
