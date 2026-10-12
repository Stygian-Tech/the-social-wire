import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { ChatBskyConvoDefs } from "@atproto/api";
import { SocialConversationRow } from "@/components/Social/SocialConversationRow";

const convo: ChatBskyConvoDefs.ConvoView = { id: "conversation", rev: "rev", members: [], muted: false, unreadCount: 123, lastMessage: { $type: "chat.bsky.convo.defs#messageView", id: "message", rev: "rev", text: "Latest conversation message", sender: { did: "did:plc:viewer" }, sentAt: "2026-10-11T00:00:00Z" } };
const restores: (() => void)[] = [];
beforeEach(() => {
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function row(overrides: Partial<Parameters<typeof SocialConversationRow>[0]> = {}) {
  const onAction = mock(() => {});
  const onSelect = mock(() => {});
  const result = render(<SocialConversationRow convo={convo} viewerDid="did:plc:viewer" name="A Long Conversation Participant Name" selected={false} pending={false} previewHidden={false} onSelect={onSelect} onAction={onAction} {...overrides} />);
  return { ...result, onAction, onSelect };
}
describe("conversation sidebar row", () => {
  it("shows the latest message, exact unread count, full name, and muted state", () => {
    const { onSelect } = row({ convo: { ...convo, muted: true }, selected: true });
    expect(screen.getByText("You: Latest conversation message")).not.toBeNull();
    expect(screen.getByLabelText("123 Unread Messages").textContent).toBe("123");
    expect(screen.getByRole("img", { name: "Muted Conversation" })).not.toBeNull();
    const selection = screen.getByRole("button", { name: /A Long Conversation Participant Name.*Latest conversation message/ });
    expect(selection.getAttribute("aria-current")).toBe("true");
    fireEvent.click(selection);
    expect(onSelect).toHaveBeenCalledTimes(1);
  });
  it("hides moderated text and removes the unread badge for read conversations", () => {
    row({ previewHidden: true, convo: { ...convo, unreadCount: 0 } });
    expect(screen.getByText("Message Hidden")).not.toBeNull();
    expect(screen.queryByText(/Latest conversation message/)).toBeNull();
    expect(screen.queryByLabelText(/Unread Messages/)).toBeNull();
  });
  it("offers read, unmute, and deletion from the accessible dropdown without selecting the row", async () => {
    const { onAction, onSelect } = row({ convo: { ...convo, muted: true } });
    fireEvent.click(screen.getByRole("button", { name: "More Actions For A Long Conversation Participant Name" }));
    await screen.findByRole("menuitem", { name: "Mark As Read" });
    expect(screen.getByRole("menuitem", { name: "Unmute Conversation" })).not.toBeNull();
    expect(screen.getByRole("menuitem", { name: "Delete Conversation" })).not.toBeNull();
    expect(screen.queryByRole("menuitem", { name: "Mark As Unread" })).toBeNull();
    fireEvent.click(screen.getByRole("menuitem", { name: "Unmute Conversation" }));
    expect(onAction).toHaveBeenCalledWith("unmute");
    expect(onSelect).toHaveBeenCalledTimes(0);
  });
  it("opens the right-click menu on the entire row and requests deletion", async () => {
    const { container, onAction } = row();
    fireEvent.contextMenu(container.querySelector('[data-slot="context-menu-trigger"]')!, { button: 2, clientX: 10, clientY: 10 });
    await screen.findByRole("menuitem", { name: "Delete Conversation" });
    expect(screen.getByRole("menuitem", { name: "Mute Conversation" })).not.toBeNull();
    fireEvent.click(screen.getByRole("menuitem", { name: "Delete Conversation" }));
    expect(onAction).toHaveBeenCalledWith("leave");
  });
  it("disables selection and menu mutations while another action is pending", () => {
    row({ pending: true });
    expect((screen.getByRole("button", { name: "More Actions For A Long Conversation Participant Name" }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: /A Long Conversation Participant Name.*Latest conversation message/ }) as HTMLButtonElement).disabled).toBe(true);
  });
});
