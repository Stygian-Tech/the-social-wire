import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { SocialNewConversationDialog } from "@/components/Social/SocialNewConversationDialog";
import type { ChatAction } from "@/lib/blueskyChatClient";

import * as auth from "@/hooks/useAuth";
import * as catalog from "@/hooks/useBlueskySocialCatalog";
import * as discovery from "@/hooks/useSocialDiscovery";

const restores: (() => void)[] = [];
beforeEach(() => {
  const spies = [spyOn(auth, "useAuth").mockReturnValue({ session: undefined } as unknown as ReturnType<typeof auth.useAuth>), spyOn(catalog, "useBlueskySocialCatalog").mockReturnValue({} as ReturnType<typeof catalog.useBlueskySocialCatalog>), spyOn(discovery, "useSocialExplore").mockReturnValue({} as ReturnType<typeof discovery.useSocialExplore>)];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
  for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
async function open(perform: (action: ChatAction) => Promise<unknown>, assertViewer = () => {}, onSent = mock(() => {})) {
  render(<SocialNewConversationDialog initialMessage="First draft" disabled={false} perform={perform} assertViewer={assertViewer} onSent={onSent} />);
  fireEvent.click(screen.getByRole("button", { name: "New Conversation" }));
  await screen.findByRole("dialog");
  fireEvent.change(screen.getByLabelText("Recipient Handle Or DID"), { target: { value: "other.test" } });
  return onSent;
}
describe("new conversation dialog", () => {
  it("retains a failed first message and retries the created conversation without creating again", async () => {
    let sends = 0;
    const perform = mock(async (action: ChatAction) => {
      if (action.kind === "start") return { convo: { id: "created" } };
      if (++sends === 1) throw new Error("Send unavailable");
      return {};
    });
    const onSent = await open(perform);
    fireEvent.change(screen.getByLabelText("First Message"), { target: { value: "Keep my message" } });
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await screen.findByText("This conversation action could not be completed. Please try again.");
    expect((screen.getByLabelText("First Message") as HTMLTextAreaElement).value).toBe("Keep my message");
    expect((screen.getByLabelText("Recipient Handle Or DID") as HTMLInputElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await waitFor(() => expect(onSent).toHaveBeenCalledWith("created"));
    expect(perform.mock.calls.map(call => call[0].kind)).toEqual(["start", "send", "send"]);
    expect(perform.mock.calls[2]![0]).toEqual({ kind: "send", convoId: "created", text: "Keep my message" });
  });
  it("locks duplicate submission and does not send after the account changes during creation", async () => {
    let resolve!: (value: unknown) => void;
    let current = true;
    const perform = mock(async () => new Promise(value => { resolve = value; }));
    await open(perform, () => { if (!current) throw new Error("Account changed"); });
    const form = screen.getByLabelText("First Message").closest("form")!;
    fireEvent.submit(form); fireEvent.submit(form);
    expect(perform).toHaveBeenCalledTimes(1);
    current = false; resolve({ convo: { id: "created" } });
    await screen.findByText("Account changed");
    expect(perform).toHaveBeenCalledTimes(1);
    expect((screen.getByLabelText("First Message") as HTMLTextAreaElement).value).toBe("First draft");
  });
  it("preserves fields after creation failure and resets them when reopened", async () => {
    const perform = mock(async () => { throw new Error("Recipient unavailable"); });
    await open(perform);
    fireEvent.click(screen.getByRole("button", { name: "Send Message" }));
    await screen.findByText("This conversation action could not be completed. Please try again.");
    expect((screen.getByLabelText("Recipient Handle Or DID") as HTMLInputElement).value).toBe("other.test");
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog") === null).toBe(true));
    fireEvent.click(screen.getByRole("button", { name: "New Conversation" }));
    await screen.findByRole("dialog");
    expect((screen.getByLabelText("Recipient Handle Or DID") as HTMLInputElement).value).toBe("");
    expect((screen.getByLabelText("First Message") as HTMLTextAreaElement).value).toBe("First draft");
  });
});
