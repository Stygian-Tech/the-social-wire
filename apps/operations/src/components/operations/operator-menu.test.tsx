import { describe, expect, it, mock } from "bun:test"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { OperatorMenu } from "@/components/operations/operator-menu"

describe("OperatorMenu", () => {
  it("opens the operator menu and logs out", async () => {
    const onSignOut = mock(async () => undefined)
    const user = userEvent.setup({ document: globalThis.document })

    render(<OperatorMenu operator="did:plc:test-operator" onSignOut={onSignOut} />)

    await user.click(screen.getByRole("button", { name: "Operator Menu" }))
    expect(within(screen.getByRole("menu")).getByText("did:plc:test-operator")).toBeDefined()

    await user.click(screen.getByRole("menuitem", { name: "Log Out" }))
    expect(onSignOut).toHaveBeenCalledTimes(1)
  })
})
