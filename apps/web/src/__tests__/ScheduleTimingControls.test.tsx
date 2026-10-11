import { afterEach, expect, mock, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { ScheduleTimingControls } from "@/components/Social/ScheduleTimingControls";

afterEach(cleanup);
test("switches publishing mode explicitly and validates a local future time", () => {
  const mode = mock(() => {}), change = mock(() => {});
  const view = render(<ScheduleTimingControls mode="now" value="" disabled={false} onModeChange={mode} onChange={change} />);
  expect(screen.queryByLabelText("Publish At")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Schedule" }));
  expect(mode).toHaveBeenCalledWith("schedule");
  view.rerender(<ScheduleTimingControls mode="schedule" value="2000-01-01T12:00" disabled={false} onModeChange={mode} onChange={change} />);
  expect(screen.getByRole("alert").textContent).toContain("Future Time");
  expect(screen.getByText(/At Least One Minute/).textContent).toContain(Intl.DateTimeFormat().resolvedOptions().timeZone);
  fireEvent.change(screen.getByLabelText("Publish At"), { target: { value: "2099-01-01T12:00" } });
  expect(change).toHaveBeenCalledWith("2099-01-01T12:00");
});
