import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Profiles from "@/lib/brandAccounts/brandAccountPublicProfile";
import * as Images from "@/hooks/useCachedImageUrl";
import * as Network from "@/lib/atprotoNetwork";
import { BrandAccountSidebarRow } from "@/components/BrandAccounts/BrandAccountSidebarRow";

const did = "did:plc:brand";
const restores: (() => void)[] = [];
let client: QueryClient;
beforeEach(() => {
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const images = spyOn(Images, "useCachedImageUrl").mockImplementation(src => ({ objectUrl: src || undefined, failed: false })); restores.push(() => images.mockRestore());
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://public.example", plcDirectory: "https://plc.directory", handleResolver: "https://public.example", appViewDid: "did:web:api.bsky.app" }); restores.push(() => network.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function mount(selected = true, disabled = false) {
  const onSelect = mock(() => {}), onUnlink = mock(() => {});
  const view = render(<QueryClientProvider client={client}><BrandAccountSidebarRow did={did} selected={selected} disabled={disabled} onSelect={onSelect} onUnlink={onUnlink} /></QueryClientProvider>);
  return { ...view, onSelect, onUnlink };
}
test("shows public avatar, name and handle with accessible DID and preserves selection/unlink", async () => {
  const profile = spyOn(Profiles, "getBrandAccountPublicProfile").mockResolvedValue({ did, displayName: "The Brand", handle: "brand.test", avatar: "https://images.example/avatar.png" }); restores.push(() => profile.mockRestore());
  const { onSelect, onUnlink } = mount();
  const button = await screen.findByRole("button", { name: `Select Brand Account: The Brand @brand.test · ${did}` });
  expect(screen.getByText("The Brand")).toBeTruthy(); expect(screen.getByText("@brand.test")).toBeTruthy();
  expect(screen.getByRole("img", { name: "The Brand" }).getAttribute("src")).toBe("https://images.example/avatar.png");
  expect(button.getAttribute("aria-pressed")).toBe("true"); expect(button.getAttribute("title")).toBe(did);
  expect(profile).toHaveBeenCalledWith(did, "https://public.example", expect.any(AbortSignal));
  fireEvent.click(button); fireEvent.click(screen.getByRole("button", { name: "Unlink Account" }));
  expect(onSelect).toHaveBeenCalledTimes(1); expect(onUnlink).toHaveBeenCalledTimes(1);
});
test("uses a readable fallback with identity retained when public metadata is unavailable", async () => {
  const profile = spyOn(Profiles, "getBrandAccountPublicProfile").mockRejectedValue(new Error("Unavailable")); restores.push(() => profile.mockRestore());
  mount(false, true);
  expect(await screen.findByText("Profile Unavailable")).toBeTruthy(); expect(screen.getByText("Linked Brand Account")).toBeTruthy();
  expect(screen.getByRole("button", { name: `Select Brand Account: ${did}` }).getAttribute("aria-pressed")).toBe("false");
  expect((screen.getByRole("button", { name: "Unlink Account" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByRole("img")).toBeNull(); expect(screen.queryByText(did)).toBeNull();
});
test("does not show mismatched identity even if a stale or malformed query result is supplied", async () => {
  const profile = spyOn(Profiles, "getBrandAccountPublicProfile").mockResolvedValue({ did: "did:plc:other", displayName: "Wrong Account", handle: "other.test", avatar: "https://images.example/wrong.png" }); restores.push(() => profile.mockRestore());
  mount();
  expect(await screen.findByText("Profile Unavailable")).toBeTruthy(); expect(screen.queryByText("Wrong Account")).toBeNull(); expect(screen.queryByRole("img")).toBeNull();
});
