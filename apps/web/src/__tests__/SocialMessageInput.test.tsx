import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { SocialMessageInput } from "@/components/Social/SocialMessageInput";
afterEach(cleanup);
describe("compact chat input", () => {
  it("sends Enter, keeps Shift Enter and IME composition, and respects pending", () => {
    const send = mock(() => {});
    const props = { id: "message", label: "Message", text: "Draft", onChange: () => {}, valid: true, pending: false, onSend: send };
    const view = render(<form><SocialMessageInput {...props} /></form>);
    const input = screen.getByLabelText("Message");
    fireEvent.keyDown(input, { key: "Enter", shiftKey: true });
    fireEvent.keyDown(input, { key: "Enter", isComposing: true });
    fireEvent.keyDown(input, { key: "Enter", keyCode: 229 });
    expect(send).not.toHaveBeenCalled();
    fireEvent.keyDown(input, { key: "Enter" });
    expect(send).toHaveBeenCalledTimes(1);
    view.rerender(<form><SocialMessageInput {...props} pending /></form>);
    fireEvent.keyDown(input, { key: "Enter" });
    expect(send).toHaveBeenCalledTimes(1);
    expect((screen.getByRole("button", { name: "Send Message" }) as HTMLButtonElement).disabled).toBe(true);
  });
  it("grows with text and caps input height without losing the draft", () => {
    const props = { id: "message", label: "Message", text: "Draft", onChange: () => {}, valid: true, pending: false, onSend: () => {} };
    const view = render(<SocialMessageInput {...props} />);
    const input = screen.getByLabelText("Message") as HTMLTextAreaElement;
    expect(input.closest(".floating-glass")?.classList.contains("floating-glass")).toBe(true);
    expect(input.closest(".floating-glass")?.classList.contains("border-border/60")).toBe(true);
    expect(input.closest(".floating-glass")?.classList.contains("rounded-3xl")).toBe(true);
    Object.defineProperty(input, "scrollHeight", { configurable: true, value: 500 });
    view.rerender(<SocialMessageInput {...props} text="Long multiline draft" />);
    expect(input.style.height).toBe("160px");
    expect(input.value).toBe("Long multiline draft");
  });
});
