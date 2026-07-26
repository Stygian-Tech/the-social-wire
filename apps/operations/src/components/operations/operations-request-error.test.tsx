import { expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import { OperationsRequestError } from "@/components/operations/operations-request-error"
import { OperationsHttpError } from "@/lib/operations-api"

test("renders exact HTTP 429 status, message, and Retry-After guidance", () => {
  render(
    <p role="alert">
      <OperationsRequestError error={new OperationsHttpError(429, "Recovery rate limit exceeded", "30")} />
    </p>,
  )

  expect(screen.getByText("HTTP 429: Recovery rate limit exceeded")).toBeTruthy()
  expect(
    screen.getByText("Retry-After: 30. Wait for the server-defined retry window before trying again."),
  ).toBeTruthy()
})
