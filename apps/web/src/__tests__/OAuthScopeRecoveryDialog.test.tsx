import { afterAll, afterEach, beforeAll, expect, it } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { AuthProvider, useAuth } from "@/hooks/useAuth";
import { OAuthScopeRecoveryDialog } from "@/components/Auth/OAuthScopeRecoveryDialog";

const keys = ["DOMRect", "Element", "HTMLElement", "Node", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"] as const;
const originals = new Map(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
beforeAll(() => {
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: (id: ReturnType<typeof setTimeout>) => clearTimeout(id) };
  for (const key of keys) Object.defineProperty(globalThis, key, {configurable:true,writable:true,value:values[key]});
});
afterAll(() => { for (const key of keys) { const original = originals.get(key); if (original) Object.defineProperty(globalThis,key,original); else Reflect.deleteProperty(globalThis,key); } });
afterEach(cleanup);

it("offers an accessible dismissible login prompt without starting OAuth on open", async () => {
  let starts = 0;
  let closed = false;
  render(<><input aria-label="Draft" defaultValue="Unpublished text" /><OAuthScopeRecoveryDialog open onOpenChange={open => {closed = !open;}} onSignIn={async () => {starts++;}} /></>);
  expect(screen.getByRole("dialog",{name:"Log In Again"})).toBeTruthy();
  expect(starts).toBe(0);
  fireEvent.click(screen.getByRole("button",{name:"Cancel"}));
  await waitFor(() => expect(closed).toBe(true));
  expect((screen.getByLabelText("Draft") as HTMLInputElement).value).toBe("Unpublished text");
  expect(starts).toBe(0);
});
it("requires an explicit tap and never exposes authorization failure details", async () => {
  let starts = 0;
  render(<OAuthScopeRecoveryDialog open onOpenChange={() => {}} onSignIn={async () => { starts++; throw new Error('Missing required scope credentials-secret'); }} />);
  fireEvent.click(screen.getByRole("button",{name:"Log In Again"}));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Couldn’t Start Login. Please Try Again."));
  expect(starts).toBe(1);
  expect(screen.queryByText(/credentials-secret/)).toBeNull();
  expect((screen.getByRole("button",{name:"Log In Again"}) as HTMLButtonElement).disabled).toBe(false);
});

it("keeps account and action state mounted when the shared provider prompts for a missing scope", async () => {
  const priorEnv = process.env.NEXT_PUBLIC_APP_ENV;
  const priorDummy = process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
  process.env.NEXT_PUBLIC_APP_ENV = "prod";
  process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "true";
  let apply: ReturnType<typeof useAuth>["applyOAuthSession"] | undefined;
  let current: OAuthSession | null = null;
  function Probe() {
    const auth = useAuth();
    apply = auth.applyOAuthSession;
    current = auth.getOAuthSession();
    return <><p>{auth.session?.did}</p><input aria-label="Pending Selection" defaultValue="Football" /></>;
  }
  try {
    render(<AuthProvider><Probe /></AuthProvider>);
    await act(async () => apply?.({did:"did:plc:scope-test",fetchHandler:async () => { throw new Error('Missing required scope "repo:app.thesocialwire.sports.selection?action=create"'); }} as unknown as OAuthSession));
    await act(async () => { try { await current!.fetchHandler("/xrpc/write"); } catch { /* The owning action retains its ordinary rollback path. */ } });
    expect(screen.getByRole("dialog", {name:"Log In Again"})).toBeTruthy();
    expect(screen.getByText("did:plc:scope-test")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", {name:"Cancel"}));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect((screen.getByLabelText("Pending Selection") as HTMLInputElement).value).toBe("Football");
    expect(screen.getByText("did:plc:scope-test")).toBeTruthy();
  } finally {
    if (priorEnv === undefined) delete process.env.NEXT_PUBLIC_APP_ENV; else process.env.NEXT_PUBLIC_APP_ENV = priorEnv;
    if (priorDummy === undefined) delete process.env.NEXT_PUBLIC_USE_DUMMY_DATA; else process.env.NEXT_PUBLIC_USE_DUMMY_DATA = priorDummy;
  }
});
