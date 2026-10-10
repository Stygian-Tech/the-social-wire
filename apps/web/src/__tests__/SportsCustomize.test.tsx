import { afterAll, beforeAll, afterEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { SportsCustomize } from "@/components/SportsCustomize";
import { acknowledgeSportsPublicInterests, readSportsPublicInterestConsent } from "@/lib/sportsPublicInterestConsent";
import * as Sports from "@/lib/sportsFeedClient";

const globalKeys = ["DOMRect", "Element", "HTMLElement", "Node", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"] as const;
const originals = new Map(globalKeys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
beforeAll(() => {
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle) };
  for (const key of globalKeys) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value: values[key] });
});
afterAll(() => {
  for (const key of globalKeys) {
    const original = originals.get(key);
    if (original) Object.defineProperty(globalThis, key, original);
    else Reflect.deleteProperty(globalThis, key);
  }
});
const restores: (() => void)[] = [];
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); for (const restore of restores.splice(0)) restore(); window.localStorage.clear(); });

function harness(viewerDID: string | undefined, signedIn = true, save = mock(async (args: { selection: Sports.SportsSelection; remove: boolean }) => { void args; return undefined; }), selections: Sports.SportsSelection[] = []) {
  const catalog = spyOn(Sports, "getSportsCatalog").mockResolvedValue({ enabled: true, available: true, eventsEnabled: false, version: "test", feeds: [], entities: [{ id: "tennis", name: "Tennis", kind: "sport", competitionIDs: [], aliases: [], active: true }, { id: "football", name: "Football", kind: "sport", competitionIDs: [], aliases: [], active: true }] });
  const search = spyOn(Sports, "searchSportsEntities").mockResolvedValue({ entities: [] });
  restores.push(() => catalog.mockRestore(), () => search.mockRestore());
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  restores.push(() => client.clear());
  const view = (open: boolean, did = viewerDID, authenticated = signedIn) => <QueryClientProvider client={client}><SportsCustomize open={open} onOpenChange={() => {}} viewerDID={did} selections={selections} save={save} saving={false} signedIn={authenticated} /></QueryClientProvider>;
  return { client, save, search, view };
}

it("requires explicit acknowledgement above Customize before a public interest can be saved", async () => {
  const did = "did:plc:sports-consent-first";
  const { save, view } = harness(did);
  render(view(true));
  await waitFor(() => expect(screen.getByRole("dialog", { name: "Your Sports Interests Are Public" })).toBeTruthy());
  expect(screen.queryByRole("checkbox", { hidden: true })).toBeNull();
  const follows = await screen.findAllByRole("button", { name: "Follow", hidden: true });
  expect(follows.every(button => (button as HTMLButtonElement).disabled)).toBe(true);
  expect(screen.getAllByRole("button", { name: "Mute", hidden: true }).every(button => (button as HTMLButtonElement).disabled)).toBe(true);
  expect(save).not.toHaveBeenCalled();
  expect(readSportsPublicInterestConsent(did)).toBe(false);
  fireEvent.click(screen.getByRole("button", { name: "I Understand" }));
  await waitFor(() => expect(screen.queryByRole("dialog", { name: "Your Sports Interests Are Public" })).toBeNull());
  expect(screen.getByRole("dialog", { name: "Customize Sports" })).toBeTruthy();
  expect(readSportsPublicInterestConsent(did)).toBe(true);
  fireEvent.click(screen.getAllByRole("button", { name: "Follow" })[0]!);
  await waitFor(() => expect(save).toHaveBeenCalledTimes(1));
  expect(save.mock.calls[0]?.[0]).toMatchObject({ selection: { reference: "football", action: "follow" }, remove: false });
});

it("remembers acknowledgement across reopen and remount while resetting search and errors", async () => {
  const did = "did:plc:sports-consent-reopen";
  const save = mock(async (args: { selection: Sports.SportsSelection; remove: boolean }) => { void args; throw new Error("Write Failed"); });
  const { view, search } = harness(did, true, save);
  const mounted = render(view(true));
  fireEvent.click(await screen.findByRole("button", { name: "I Understand" }));
  fireEvent.click((await screen.findAllByRole("button", { name: "Follow" }))[0]!);
  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Write Failed"));
  fireEvent.change(screen.getByRole("searchbox"), { target: { value: "Celtics" } });
  await waitFor(() => expect(search).toHaveBeenCalledWith("Celtics", expect.anything()));
  mounted.rerender(view(false));
  mounted.rerender(view(true));
  await waitFor(() => expect((screen.getByRole("searchbox") as HTMLInputElement).value).toBe(""));
  expect(screen.queryByRole("alert")).toBeNull();
  expect(screen.queryByRole("button", { name: "I Understand" })).toBeNull();
  expect(screen.getAllByRole("button", { name: "Follow" }).every(button => !(button as HTMLButtonElement).disabled)).toBe(true);
  mounted.unmount();
  render(view(true));
  await waitFor(() => expect(screen.getAllByRole("button", { name: "Follow" }).every(button => !(button as HTMLButtonElement).disabled)).toBe(true));
  expect(screen.queryByRole("button", { name: "I Understand" })).toBeNull();
});

it("asks another account to acknowledge and disables actions during the account handoff", async () => {
  const { view, save } = harness("did:plc:sports-consent-account-a");
  const mounted = render(view(true));
  fireEvent.click(await screen.findByRole("button", { name: "I Understand" }));
  mounted.rerender(view(true, "did:plc:sports-consent-account-b"));
  await waitFor(() => expect(screen.getByRole("button", { name: "I Understand" })).toBeTruthy());
  expect(screen.getAllByRole("button", { name: "Follow", hidden: true }).every(button => (button as HTMLButtonElement).disabled)).toBe(true);
  expect(readSportsPublicInterestConsent("did:plc:sports-consent-account-b")).toBe(false);
  expect(save).not.toHaveBeenCalled();
});

it("cancelling the confirmation closes both dialogs without recording consent or writing", async () => {
  const did = "did:plc:sports-consent-cancel";
  const { client, save } = harness(did);
  function Controlled() {
    const [open, setOpen] = useState(true);
    return <QueryClientProvider client={client}><SportsCustomize open={open} onOpenChange={setOpen} viewerDID={did} selections={[]} save={save} saving={false} signedIn /></QueryClientProvider>;
  }
  render(<Controlled />);
  fireEvent.click(await screen.findByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(readSportsPublicInterestConsent(did)).toBe(false);
  expect(save).not.toHaveBeenCalled();
});

it("does not prompt signed-out viewers and keeps public write actions disabled", async () => {
  const { view, save } = harness(undefined, false, mock(async (args: { selection: Sports.SportsSelection; remove: boolean }) => { void args; return undefined; }), [{ reference: "football", action: "follow", createdAt: "2026-10-04T00:00:00Z", updatedAt: "2026-10-04T00:00:00Z" }]);
  render(view(true));
  const follows = await screen.findAllByRole("button", { name: "Follow" });
  expect(screen.queryByRole("button", { name: "I Understand" })).toBeNull();
  expect(follows.every(button => (button as HTMLButtonElement).disabled)).toBe(true);
  expect((screen.getByRole("button", { name: "Remove" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(follows[0]!);
  fireEvent.click(screen.getByRole("button", { name: "Remove" }));
  expect(save).not.toHaveBeenCalled();
});

it("localizes sport choices and saved interests while preserving proper team names", async () => {
  const navigatorProperties = ["language", "languages"] as const;
  const originalNavigator = new Map(navigatorProperties.map(key => [key, Object.getOwnPropertyDescriptor(navigator, key)]));
  restores.push(() => {
    for (const key of navigatorProperties) {
      const original = originalNavigator.get(key);
      if (original) Object.defineProperty(navigator, key, original);
      else Reflect.deleteProperty(navigator, key);
    }
  });
  const setLocale = (locale: string) => {
    Object.defineProperty(navigator, "language", { configurable: true, value: locale });
    Object.defineProperty(navigator, "languages", { configurable: true, value: [locale] });
    act(() => { window.dispatchEvent(new window.Event("languagechange")); });
  };
  setLocale("en-GB");
  const entities: Sports.SportsEntity[] = [
    { id: "gridiron", name: "American Football", kind: "sport", competitionIDs: [], aliases: [], active: true },
    { id: "association", name: "Football", kind: "sport", competitionIDs: [], aliases: [], active: true },
    { id: "mount-union", name: "Mount Union Football", kind: "ncaa-team", sportID: "gridiron", competitionIDs: [], aliases: [], active: true },
  ];
  const catalog = spyOn(Sports, "getSportsCatalog").mockResolvedValue({ enabled: true, available: true, eventsEnabled: false, version: "locale-test", feeds: [], entities });
  const search = spyOn(Sports, "searchSportsEntities").mockResolvedValue({ entities: [entities[2]!] });
  restores.push(() => catalog.mockRestore(), () => search.mockRestore());
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  restores.push(() => client.clear());
  const viewerDID = "did:plc:sports-locale-customize";
  acknowledgeSportsPublicInterests(viewerDID);
  const selections: Sports.SportsSelection[] = [
    { reference: "gridiron", action: "follow", createdAt: "2026-10-04T00:00:00Z", updatedAt: "2026-10-04T00:00:00Z" },
    { reference: "association", action: "mute", createdAt: "2026-10-04T00:00:00Z", updatedAt: "2026-10-04T00:00:00Z" },
    { reference: "mount-union", action: "follow", createdAt: "2026-10-04T00:00:00Z", updatedAt: "2026-10-04T00:00:00Z" },
  ];
  render(<QueryClientProvider client={client}><SportsCustomize open onOpenChange={() => {}} viewerDID={viewerDID} signedIn selections={selections} saving={false} save={async () => undefined} /></QueryClientProvider>);
  await waitFor(() => expect(screen.getByText("American Football · Following")).toBeTruthy());
  expect(screen.getByText("Football · Muted")).toBeTruthy();
  expect(screen.getByText("American Football", { selector: "p.font-medium" })).toBeTruthy();
  expect(screen.getByText("Football", { selector: "p.font-medium" })).toBeTruthy();
  expect(screen.getByText("Mount Union Football · Following")).toBeTruthy();
  setLocale("en-US");
  await waitFor(() => expect(screen.getByText("Football · Following")).toBeTruthy());
  expect(screen.getByText("Soccer · Muted")).toBeTruthy();
  expect(screen.getByText("Football", { selector: "p.font-medium" })).toBeTruthy();
  expect(screen.getByText("Soccer", { selector: "p.font-medium" })).toBeTruthy();
  expect(screen.getByText("Mount Union Football · Following")).toBeTruthy();
  fireEvent.change(screen.getByRole("searchbox"), { target: { value: "Mount Union" } });
  await waitFor(() => expect(screen.getByText("NCAA Team · Football")).toBeTruthy());
  expect(screen.getByText("Mount Union Football", { selector: "p.font-medium" })).toBeTruthy();
  setLocale("en-GB");
  await waitFor(() => expect(screen.getByText("NCAA Team · American Football")).toBeTruthy());
  expect(screen.getByText("Mount Union Football", { selector: "p.font-medium" })).toBeTruthy();
  expect(entities.map(entity => entity.name)).toEqual(["American Football", "Football", "Mount Union Football"]);
});

it.each([{width:320,height:568},{width:392,height:420},{width:1024,height:360}])("constrains a long Customize dialog to the viewport with an independently scrolling body: %j",async viewport=>{
 const width=Object.getOwnPropertyDescriptor(window,"innerWidth")!;const height=Object.getOwnPropertyDescriptor(window,"innerHeight")!;
 Object.defineProperty(window,"innerWidth",{configurable:true,value:viewport.width});Object.defineProperty(window,"innerHeight",{configurable:true,value:viewport.height});restores.push(()=>Object.defineProperty(window,"innerWidth",width),()=>Object.defineProperty(window,"innerHeight",height));
 const did="did:plc:sports-responsive";acknowledgeSportsPublicInterests(did);
 const selections=Array.from({length:40},(_,i)=>({reference:`interest-${i}`,action:"follow" as const,createdAt:"now",updatedAt:"now"}));
 const {view,search}=harness(did,true,undefined,selections);
 const longNames=Array.from({length:30},(_,i)=>({id:`result-${i}`,name:`Very Long International Sports Team Display Name ${i}`,kind:"team",competitionIDs:[],aliases:[],active:true}));search.mockResolvedValue({entities:longNames});
 render(view(true));
 fireEvent.change(screen.getByRole("searchbox"),{target:{value:"International"}});
 // Allow the 300ms search debounce and the large dialog's deferred render under CI load.
 await waitFor(()=>expect(screen.getAllByRole("button",{name:"Follow"})).toHaveLength(30),{timeout:3000});
 const dialog=screen.getByRole("dialog",{name:"Customize Sports"});
 expect(dialog.classList.contains("max-h-[calc(100dvh-2rem)]")).toBe(true);expect(dialog.classList.contains("w-[calc(100vw-2rem)]")).toBe(true);expect(dialog.classList.contains("sm:max-w-2xl")).toBe(true);expect(dialog.classList.contains("overflow-hidden")).toBe(true);
 const body=dialog.querySelector("[data-sports-customize-body]")!;const footer=dialog.querySelector("[data-sports-customize-footer]")!;
 expect(body.classList.contains("min-h-0")).toBe(true);expect(body.classList.contains("overflow-y-auto")).toBe(true);expect(body.classList.contains("[overflow-wrap:anywhere]")).toBe(true);
 expect(body.contains(screen.getByRole("searchbox"))).toBe(true);expect(body.contains(screen.getAllByRole("button",{name:"Remove"})[39]!)).toBe(true);
 expect(body.contains(screen.getByRole("heading",{name:"Customize Sports"}))).toBe(false);expect(footer.classList.contains("shrink-0")).toBe(true);expect(body.contains(footer)).toBe(false);expect(footer.querySelector("button")?.textContent).toBe("Close");
 expect(screen.getByText("Very Long International Sports Team Display Name 29")).toBeTruthy();
});
