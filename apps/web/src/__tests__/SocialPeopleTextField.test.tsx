import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { useState } from "react";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { SocialPeopleTextField } from "@/components/Social/SocialPeopleTextField";
import * as auth from "@/hooks/useAuth";
import * as catalog from "@/hooks/useBlueskySocialCatalog";
import * as discovery from "@/hooks/useSocialDiscovery";
import type { ModerationOpts } from "@atproto/api";
const restores: (() => void)[] = [];
const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
let queries: string[] = [];
let safety: ModerationOpts = moderation;
beforeEach(() => {
  queries = []; safety = moderation;
  const spies = [
    spyOn(auth, "useAuth").mockReturnValue({ session: { did: moderation.userDid } } as ReturnType<typeof auth.useAuth>),
    spyOn(catalog, "useBlueskySocialCatalog").mockImplementation(() => ({ data: { moderation: safety } } as unknown as ReturnType<typeof catalog.useBlueskySocialCatalog>)),
    spyOn(discovery, "useSocialExplore").mockImplementation((query, _kind, safety) => {
      if (safety) queries.push(query);
      return { data: { pages: [{ actors: [{ did: "did:plc:alice", handle: "alice.test", displayName: "Alice" }, { did: "did:plc:bob", handle: "bob.test", displayName: "Bob" }, { did: "did:plc:blocked", handle: "blocked.test", displayName: "Blocked", viewer: { blocking: "at://did:plc:viewer/app.bsky.graph.block/example" } }] }] } } as unknown as ReturnType<typeof discovery.useSocialExplore>;
    }),
  ];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
  const original = Object.getOwnPropertyDescriptor(globalThis, "requestAnimationFrame");
  Object.defineProperty(globalThis, "requestAnimationFrame", { configurable: true, writable: true, value: (callback: FrameRequestCallback) => { callback(0); return 0; } });
  restores.push(() => { if (original) Object.defineProperty(globalThis, "requestAnimationFrame", original); else Reflect.deleteProperty(globalThis, "requestAnimationFrame"); });
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function Field({ recipient = false }: { recipient?: boolean }) {
  const [text, setText] = useState("");
  return <SocialPeopleTextField recipient={recipient} aria-label="Draft" value={text} onValueChange={setText} />;
}
it("debounces and inserts a keyboard-selected mention without sending", async () => {
  render(<Field />);
  const input = screen.getByLabelText("Draft");
  fireEvent.focus(input);
  fireEvent.change(input, { target: { value: "Hi @al", selectionStart: 6 } });
  expect(queries).toEqual([]);
  await screen.findByRole("option", { name: "Alice @alice.test" });
  fireEvent.keyDown(input, { key: "ArrowDown" });
  fireEvent.keyDown(input, { key: "Enter" });
  expect((input as HTMLTextAreaElement).value).toBe("Hi @bob.test ");
  expect(screen.queryByRole("listbox")).toBeNull();
});
it("uses the same picker for a recipient and Escape dismisses it", async () => {
  render(<Field recipient />);
  const input = screen.getByLabelText("Draft");
  fireEvent.focus(input);
  fireEvent.change(input, { target: { value: "alice", selectionStart: 5 } });
  await screen.findByRole("option", { name: "Alice @alice.test" });
  fireEvent.keyDown(input, { key: "Escape" });
  expect(screen.queryByRole("listbox")).toBeNull();
  fireEvent.change(input, { target: { value: "alic", selectionStart: 4 } });
  fireEvent.click(await screen.findByRole("option", { name: "Alice @alice.test" }));
  await waitFor(() => expect((input as HTMLInputElement).value).toBe("alice.test"));
});

it("excludes blocked people and stale account moderation from selection", async () => {
  const view = render(<Field recipient />);
  const input = screen.getByLabelText("Draft");
  fireEvent.focus(input); fireEvent.change(input, { target: { value: "al", selectionStart: 2 } });
  await screen.findByRole("option", { name: "Alice @alice.test" });
  expect(screen.getAllByRole("option")).toHaveLength(2);
  expect(screen.queryByRole("option", { name: "Blocked @blocked.test" })).toBeNull();
  view.unmount(); safety = { ...moderation, userDid: "did:plc:previous" }; queries = [];
  render(<Field recipient />);
  const next = screen.getByLabelText("Draft");
  fireEvent.focus(next); fireEvent.change(next, { target: { value: "al", selectionStart: 2 } });
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 250)); });
  expect(screen.queryByRole("option")).toBeNull(); expect(queries).toEqual([]);
});
