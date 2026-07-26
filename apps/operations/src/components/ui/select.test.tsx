import { describe, expect, it, mock } from "bun:test"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { Select } from "@/components/ui/select"

describe("Select", () => {
  it("opens a popup and reports the chosen value", async () => {
    const onValueChange = mock(() => {})
    render(
      <Select
        ariaLabel="Source Mode"
        value="jetstream_replay"
        onValueChange={onValueChange}
        options={[
          { value: "jetstream_replay", label: "Jetstream Replay" },
          { value: "pds_reconciliation", label: "PDS Reconciliation" },
        ]}
      />,
    )

    const trigger = screen.getByRole("combobox", { name: "Source Mode" })
    expect(trigger.textContent).toContain("Jetstream Replay")
    expect(trigger.textContent).not.toContain("PDS Reconciliation")
    expect(trigger.querySelector("svg")).toBeTruthy()

    fireEvent.click(trigger)
    const option = await screen.findByRole("option", { name: "PDS Reconciliation" })
    fireEvent.click(option)

    await waitFor(() => expect(onValueChange).toHaveBeenCalledWith("pds_reconciliation"))
  })
})
