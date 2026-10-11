import { afterEach, expect, spyOn, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as profiles from "@/lib/brandAccounts/brandAccountPublicProfile";
import * as images from "@/hooks/useCachedImageUrl";
import { SocialComposeAccountPicker } from "@/components/Social/SocialComposeAccountPicker";

const restores: (() => void)[] = [];
let cache: QueryClient;
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
test("shows cached acting identity and selects a single account with chevron padding", async () => {
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const metadata = spyOn(profiles, "getBrandAccountPublicProfile").mockImplementation(async did => ({ did, handle: did === "did:plc:owner" ? "owner.test" : "brand.test", displayName: did === "did:plc:owner" ? "Personal" : "Brand", avatar: "https://images.test/avatar.png" })); restores.push(() => metadata.mockRestore());
  const image = spyOn(images, "useCachedImageUrl").mockImplementation(src => ({ objectUrl: src ?? undefined, failed: false })); restores.push(() => image.mockRestore());
  let selection: string | undefined;
  render(<QueryClientProvider client={cache}><SocialComposeAccountPicker ownerDid="did:plc:owner" accounts={["did:plc:brand"]} actorDid="did:plc:brand" disabled={false} onChange={did => { selection = did; }} /></QueryClientProvider>);
  await screen.findByRole("option", { name: "Brand @brand.test" });
  const select = screen.getByRole("combobox", { name: "Post As" });
  expect(select.className).toContain("pr-9");
  expect(screen.getByRole("presentation").getAttribute("src")).toBe("https://images.test/avatar.png");
  fireEvent.change(select, { target: { value: "did:plc:owner" } });
  expect(selection).toBe("did:plc:owner");
});
test("keeps an unlinked selected actor instead of falling back to personal", async () => {
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const metadata = spyOn(profiles, "getBrandAccountPublicProfile").mockResolvedValue({ did: "did:plc:wrong", handle: "wrong.test" }); restores.push(() => metadata.mockRestore());
  render(<QueryClientProvider client={cache}><SocialComposeAccountPicker ownerDid="did:plc:owner" accounts={[]} actorDid="did:plc:removed" disabled onChange={() => { throw new Error("No Silent Selection"); }} /></QueryClientProvider>);
  expect((screen.getByRole("combobox", { name: "Post As" }) as HTMLSelectElement).value).toBe("did:plc:removed");
  expect(screen.getByRole("option", { name: "Unlinked Brand Account" })).toBeTruthy();
  expect(screen.queryByText(/wrong.test/)).toBeNull();
  expect(screen.getByRole("combobox").hasAttribute("disabled")).toBe(true);
});
