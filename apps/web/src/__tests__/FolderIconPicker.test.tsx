import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { FolderIconPicker } from "@/components/AppSidebar/FolderIconPicker";
import { FolderIconGlyph } from "@/components/AppSidebar/FolderIcon";
import { isFolderEmoji } from "@/components/AppSidebar/folderEmoji";
import { CreateFolderFormFields } from "@/components/AppSidebar/NewFolder/CreateFolderFormFields";
import { EditFolderForm } from "@/components/AppSidebar/EditFolderForm";
import { Dialog, DialogContent } from "@/components/ui/dialog";
import * as Folders from "@/hooks/useFolders";

const restores: (() => void)[] = [];
beforeEach(() => {
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), HTMLElement: window.HTMLElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function Picker() { const [value, setValue] = useState("folder"); return <><label id="icon-label">Icon or Emoji</label><FolderIconPicker labelledBy="icon-label" value={value} onChange={setValue} /><output aria-label="Selected Icon">{value}</output><FolderIconGlyph icon={value} name="Selected Folder" /></>; }

test("accepts joined emoji, skin tones, flags, and keycaps while rejecting multiple glyphs or text", () => {
  for (const value of ["👩🏽‍💻", "🇨🇦", "1️⃣", " ❤️ "]) expect(isFolderEmoji(value)).toBe(true);
  for (const value of ["", "hello", "A", "🚀⭐"]) expect(isFolderEmoji(value)).toBe(false);
});

test("switches from icons to emoji and retains existing selection for invalid custom input", () => {
  render(<Picker />);
  fireEvent.click(screen.getByRole("radio", { name: "Engineering" }));
  expect(screen.getByLabelText("Selected Icon").textContent).toBe("code");
  fireEvent.click(screen.getByRole("radio", { name: "Rocket Emoji" }));
  expect(screen.getByLabelText("Selected Icon").textContent).toBe("🚀");
  expect(screen.getByRole("radio", { name: "Rocket Emoji" }).getAttribute("aria-checked")).toBe("true");
  fireEvent.change(screen.getByRole("textbox", { name: "Custom Emoji" }), { target: { value: "👩🏽‍💻" } });
  expect(screen.getByLabelText("Selected Icon").textContent).toBe("👩🏽‍💻");
  fireEvent.change(screen.getByRole("textbox", { name: "Custom Emoji" }), { target: { value: "not an emoji" } });
  expect(screen.getByLabelText("Selected Icon").textContent).toBe("👩🏽‍💻");
  expect(screen.getByText("Enter One Emoji to Select It.").textContent).toContain("Enter One Emoji");
});

test("creates folders with the selected emoji through the existing mutation contract", async () => {
  const mutateAsync = mock(async () => ({ uri: "at://did:plc:alice/app.thesocialwire.folder/f", rkey: "f" }));
  const create = spyOn(Folders, "useCreateFolder").mockReturnValue({ mutateAsync, reset: () => {}, isPending: false } as unknown as ReturnType<typeof Folders.useCreateFolder>);
  restores.push(() => create.mockRestore());
  await act(async () => { render(<Dialog open><DialogContent><CreateFolderFormFields onCloseRequest={() => {}} /></DialogContent></Dialog>); });
  fireEvent.change(screen.getByRole("textbox", { name: "Name" }), { target: { value: "Science" } });
  fireEvent.click(screen.getByRole("radio", { name: "Science Emoji" }));
  fireEvent.click(screen.getByRole("button", { name: "Create" }));
  await waitFor(() => expect(mutateAsync).toHaveBeenCalledWith({ name: "Science", icon: "🧪" }));
});

test("preserves stored custom emoji on editing and can switch back to a named icon", async () => {
  const mutateAsync = mock(async () => {});
  const update = spyOn(Folders, "useUpdateFolder").mockReturnValue({ mutateAsync, reset: () => {}, isPending: false } as unknown as ReturnType<typeof Folders.useUpdateFolder>);
  restores.push(() => update.mockRestore());
  await act(async () => { render(<Dialog open><EditFolderForm folderUri="at://did:plc:alice/app.thesocialwire.folder/f" folder={{ name: "Tech", icon: "👩🏽‍💻" }} onOpenChange={() => {}} /></Dialog>); });
  expect((screen.getByRole("textbox", { name: "Custom Emoji" }) as HTMLInputElement).value).toBe("👩🏽‍💻");
  fireEvent.click(screen.getByRole("radio", { name: "Engineering" }));
  fireEvent.click(screen.getByRole("button", { name: "Save Changes" }));
  await waitFor(() => expect(mutateAsync).toHaveBeenCalledWith({ uri: "at://did:plc:alice/app.thesocialwire.folder/f", updates: { name: "Tech", icon: "code", iconImage: "" } }));
});
