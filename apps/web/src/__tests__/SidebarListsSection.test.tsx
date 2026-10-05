import {
  afterAll,
  beforeAll,
  afterEach,
  describe,
  expect,
  it,
  mock,
} from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import {
  SidebarListsSection,
  type SidebarListsSectionProps,
} from "@/components/AppSidebar/SidebarListsSection";
import { SidebarProvider } from "@/components/ui/sidebar";

const globalKeys = [
  "DOMRect",
  "Element",
  "HTMLElement",
  "Node",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const originals = new Map(
  globalKeys.map((key) => [
    key,
    Object.getOwnPropertyDescriptor(globalThis, key),
  ]),
);
const originalMatchMedia = Object.getOwnPropertyDescriptor(
  window,
  "matchMedia",
);
beforeAll(() => {
  const values = {
    DOMRect: window.DOMRect,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(performance.now()), 0),
    cancelAnimationFrame: (handle: ReturnType<typeof setTimeout>) =>
      clearTimeout(handle),
  };
  for (const key of globalKeys)
    Object.defineProperty(globalThis, key, {
      configurable: true,
      writable: true,
      value: values[key],
    });
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: () => ({
      matches: false,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
    }),
  });
});
afterAll(() => {
  for (const key of globalKeys) {
    const descriptor = originals.get(key);
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
  if (originalMatchMedia)
    Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});

const uri = "at://did:plc:alice/app.standard-reader.list/example";
const base: SidebarListsSectionProps = {
  lists: [
    {
      uri,
      name: "Technology",
      creatorDid: "did:plc:alice",
      publications: [],
      users: [],
      owned: false,
      saved: true,
    },
  ],
  creatorResults: [],
  selectedUri: uri,
  loading: false,
  searching: false,
  saving: false,
  onSelect: () => undefined,
  onSearchCreator: async () => [],
  onAdd: async () => undefined,
  onRemove: async () => undefined,
  onRefresh: async () => undefined,
};
function mount(props: Partial<SidebarListsSectionProps> = {}) {
  return render(
    <SidebarProvider>
      <SidebarListsSection {...base} {...props} />
    </SidebarProvider>,
  );
}
afterEach(cleanup);

describe("Standard Reader Lists Sidebar", () => {
  it("opens a dialog for creator search and list URLs without expanding the sidebar filter", () => {
    mount();
    expect(
      screen.queryByRole("textbox", { name: "Filter Your Lists" }),
    ).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    expect(
      screen.queryByRole("textbox", { name: "Filter Your Lists" }),
    ).toBeNull();
    expect(screen.getByRole("dialog", { name: "Add List" })).toBeDefined();
    expect(screen.getByRole("textbox", { name: "List Creator" })).toBeDefined();
    expect(
      screen.getByRole("textbox", { name: "List URL Or AT URI" }),
    ).toBeDefined();
    expect(screen.getByText(/Saved lists are public/)).toBeDefined();
  });
  it("filters local lists and searches creators only on explicit submission", async () => {
    const onSearchCreator = mock(async () => []);
    mount({ onSearchCreator });
    fireEvent.click(screen.getByRole("button", { name: "Search Lists" }));
    fireEvent.change(
      screen.getByRole("textbox", { name: "Filter Your Lists" }),
      { target: { value: "Health" } },
    );
    expect(
      within(screen.getByRole("dialog", { name: "Search Lists" })).queryByRole(
        "button",
        { name: "Technology" },
      ),
    ).toBeNull();
    expect(screen.queryByRole("textbox", { name: "List Creator" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(onSearchCreator).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.change(screen.getByRole("textbox", { name: "List Creator" }), {
      target: { value: "alice.test" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Find Creator's Lists" }),
    );
    await waitFor(() =>
      expect(onSearchCreator).toHaveBeenCalledWith("alice.test"),
    );
  });
  it("selects the exact canonical list and requires confirmation for removal", async () => {
    const onSelect = mock(() => undefined);
    const onRemove = mock(async () => undefined);
    mount({ onSelect, onRemove });
    const list = screen.getByRole("button", { name: "Technology" });
    expect(list.getAttribute("aria-current")).toBe("page");
    fireEvent.click(list);
    expect(onSelect).toHaveBeenCalledWith(uri);
    fireEvent.click(
      screen.getByRole("button", { name: "More Actions For Technology" }),
    );
    const remove = await screen.findByRole("menuitem", { name: "Remove List" });
    expect(remove.getAttribute("data-variant")).toBe("destructive");
    expect(remove.className).toContain("whitespace-nowrap");
    expect(remove.closest("[role=menu]")!.className).toContain("min-w-[11rem]");
    expect(remove.closest("[role=menu]")!.className).toContain(
      "max-w-(--available-width)",
    );
    fireEvent.click(remove);
    expect(onRemove).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Remove List" }));
    await waitFor(() => expect(onRemove).toHaveBeenCalledWith(uri));
  });
  it("shows add failures without clearing the input and prevents blank saves", async () => {
    const onAdd = mock(async () => {
      throw new Error("List Not Found");
    });
    mount({ onAdd });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    const input = screen.getByRole("textbox", { name: "List URL Or AT URI" });
    fireEvent.change(input, { target: { value: uri } });
    fireEvent.submit(input.closest("form")!);
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain("List Not Found"),
    );
    expect((input as HTMLInputElement).value).toBe(uri);
    expect(onAdd).toHaveBeenCalledWith(uri);
  });
  it("does not offer saved-list removal for owned lists or duplicate creator results", async () => {
    mount({
      lists: [{ ...base.lists[0], owned: true, saved: false }],
      creatorResults: base.lists,
    });
    fireEvent.click(
      screen.getByRole("button", { name: "More Actions For Technology" }),
    );
    expect(
      await screen.findByRole("menuitem", { name: "Copy Link" }),
    ).toBeDefined();
    expect(screen.queryByRole("menuitem", { name: "Remove List" })).toBeNull();
    expect(screen.queryByText("Creator's Lists")).toBeNull();
  });
  it("discloses public saves when adding from creator search alone", async () => {
    const onAdd = mock(async () => undefined);
    const discovered = {
      ...base.lists[0]!,
      uri: `${uri}-other`,
      name: "Health",
      saved: false,
    };
    mount({ creatorResults: [discovered], onAdd });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    expect(
      screen.getByRole("textbox", { name: "List URL Or AT URI" }),
    ).toBeDefined();
    fireEvent.change(screen.getByRole("textbox", { name: "List Creator" }), {
      target: { value: "alice.test" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Find Creator's Lists" }),
    );
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Add Health" })).toBeDefined(),
    );
    expect(screen.getByText(/Saved lists are public/)).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Add Health" }));
    await waitFor(() => expect(onAdd).toHaveBeenCalledWith(discovered.uri));
  });
  it("shows a creator empty state only after an explicit successful search", async () => {
    mount();
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    expect(
      screen.queryByText("No Public Lists Found For This Creator."),
    ).toBeNull();
    fireEvent.change(screen.getByRole("textbox", { name: "List Creator" }), {
      target: { value: "alice.test" },
    });
    fireEvent.submit(
      screen.getByRole("textbox", { name: "List Creator" }).closest("form")!,
    );
    await waitFor(() =>
      expect(
        screen.getByText("No Public Lists Found For This Creator."),
      ).toBeDefined(),
    );
  });
  it("ignores Enter submission while a save is already in progress", () => {
    const onAdd = mock(async () => undefined);
    mount({ saving: true, onAdd });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    const input = screen.getByRole("textbox", { name: "List URL Or AT URI" });
    fireEvent.change(input, { target: { value: uri } });
    fireEvent.submit(input.closest("form")!);
    expect(onAdd).not.toHaveBeenCalled();
  });
  it("shows retryable degradation without claiming that a failed empty projection has no lists", () => {
    mount({
      lists: [],
      error:
        "Some lists could not be refreshed. Showing previously loaded lists.",
    });
    expect(screen.getByRole("alert").textContent).toContain(
      "Some lists could not be refreshed",
    );
    expect(screen.getByRole("button", { name: "Retry" })).toBeDefined();
    expect(screen.queryByText("No Lists Yet.")).toBeNull();
  });

  it("passes the complete list URL to the resolver and closes only after success", async () => {
    const onAdd = mock(async () => undefined);
    mount({ onAdd });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    const url = "https://standard-reader.app/l/did:plc:alice/example";
    const input = screen.getByRole("textbox", { name: "List URL Or AT URI" });
    fireEvent.change(input, { target: { value: url } });
    fireEvent.submit(input.closest("form")!);
    await waitFor(() => expect(onAdd).toHaveBeenCalledWith(url));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  });
  it("resets the form when reopened after Cancel", async () => {
    mount();
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.change(
      screen.getByRole("textbox", { name: "List URL Or AT URI" }),
      { target: { value: uri } },
    );
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    expect(
      (
        screen.getByRole("textbox", {
          name: "List URL Or AT URI",
        }) as HTMLInputElement
      ).value,
    ).toBe("");
  });
  it("ignores a completed add from a cancelled dialog after it has reopened", async () => {
    let finish!: () => void;
    const onAdd = mock(
      () =>
        new Promise<void>((resolve) => {
          finish = resolve;
        }),
    );
    mount({ onAdd });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    const input = screen.getByRole("textbox", { name: "List URL Or AT URI" });
    fireEvent.change(input, { target: { value: uri } });
    fireEvent.submit(input.closest("form")!);
    await waitFor(() => expect(onAdd).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    finish();
    await waitFor(() =>
      expect(screen.getByRole("dialog", { name: "Add List" })).toBeDefined(),
    );
    expect(
      (
        screen.getByRole("textbox", {
          name: "List URL Or AT URI",
        }) as HTMLInputElement
      ).value,
    ).toBe("");
  });
  it("offers the same destructive action through right-click without an inline remove button", async () => {
    const onRemove = mock(async () => undefined);
    mount({ onRemove });
    expect(
      screen.queryByRole("button", { name: "Remove Technology From Lists" }),
    ).toBeNull();
    fireEvent.contextMenu(screen.getByRole("button", { name: "Technology" }));
    const remove = await screen.findByRole("menuitem", { name: "Remove List" });
    expect(remove.getAttribute("data-variant")).toBe("destructive");
    expect(remove.className).toContain("whitespace-nowrap");
    expect(remove.closest("[role=menu]")!.className).toContain("min-w-[11rem]");
    expect(remove.closest("[role=menu]")!.className).toContain(
      "max-w-(--available-width)",
    );
    fireEvent.click(remove);
    expect(
      await screen.findByRole("group", { name: "Confirm List Removal" }),
    ).toBeDefined();
    expect(onRemove).not.toHaveBeenCalled();
  });
  it("keeps confirmation and an accessible error when removal fails", async () => {
    mount({
      onRemove: async () => {
        throw new Error("Removal Failed");
      },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "More Actions For Technology" }),
    );
    fireEvent.click(
      await screen.findByRole("menuitem", { name: "Remove List" }),
    );
    fireEvent.click(screen.getByRole("button", { name: "Remove List" }));
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain("Removal Failed"),
    );
    expect(
      await screen.findByRole("group", { name: "Confirm List Removal" }),
    ).toBeDefined();
  });
  it("selects an exact local search result, closes the dialog, and never filters the sidebar", async () => {
    const onSelect = mock(() => undefined);
    mount({ onSelect });
    fireEvent.click(screen.getByRole("button", { name: "Search Lists" }));
    const dialog = screen.getByRole("dialog", { name: "Search Lists" });
    fireEvent.change(
      within(dialog).getByRole("textbox", { name: "Filter Your Lists" }),
      { target: { value: "tech" } },
    );
    fireEvent.click(within(dialog).getByRole("button", { name: "Technology" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(onSelect).toHaveBeenCalledWith(uri);
    expect(screen.getByRole("button", { name: "Technology" })).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Search Lists" }));
    expect(
      (
        screen.getByRole("textbox", {
          name: "Filter Your Lists",
        }) as HTMLInputElement
      ).value,
    ).toBe("");
  });
  it("creates a public list with selected publications and explicitly resolved creators", async () => {
    const onCreate = mock(async () => undefined);
    const onResolveCreator = mock(async () => ({
      did: "did:plc:creator",
      handle: "creator.test",
    }));
    const publicationId =
      "at://did:plc:publisher/site.standard.publication/news";
    mount({
      onCreate,
      onResolveCreator,
      publications: [
        {
          publicationId,
          title: "Science News",
          authorDid: "did:plc:publisher",
          authorHandle: "publisher.test",
        },
      ],
    });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    const dialog = screen.getByRole("dialog");
    expect(
      within(dialog).getByText(/Lists and their members are public/),
    ).toBeDefined();
    fireEvent.change(
      within(dialog).getByRole("textbox", { name: "List Name" }),
      { target: { value: "Science" } },
    );
    fireEvent.change(
      within(dialog).getByRole("textbox", { name: "Description" }),
      { target: { value: "Research reporting" } },
    );
    fireEvent.click(
      within(dialog).getByRole("checkbox", { name: /Science News/ }),
    );
    fireEvent.change(
      within(dialog).getByRole("textbox", { name: "Creator Account" }),
      { target: { value: "creator.test" } },
    );
    expect(onResolveCreator).not.toHaveBeenCalled();
    expect(onCreate).not.toHaveBeenCalled();
    fireEvent.click(
      within(dialog).getByRole("button", { name: "Add Creator" }),
    );
    await waitFor(() =>
      expect(within(dialog).getByText("@creator.test")).toBeDefined(),
    );
    fireEvent.click(
      within(dialog).getByRole("button", { name: "Create List" }),
    );
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(onCreate).toHaveBeenCalledWith({
      name: "Science",
      description: "Research reporting",
      publications: [publicationId],
      users: ["did:plc:creator"],
    });
  });
  it("shows valid publication handles and never labels a DID placeholder as a handle", () => {
    mount({
      onCreate: async () => undefined,
      onResolveCreator: async () => ({ did: "did:plc:creator" }),
      publications: [
        {
          publicationId: "at://did:plc:publisher/site.standard.publication/one",
          title: "Science News",
          authorDid: "did:plc:publisher",
          authorHandle: "did:plc:publisher",
        },
        {
          publicationId: "at://did:plc:author/site.standard.publication/two",
          title: "Local News",
          authorDid: "did:plc:author",
          authorHandle: "news.example",
        },
      ],
    });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    expect(screen.queryByText("@did:plc:publisher")).toBeNull();
    expect(screen.getByText("@news.example")).toBeDefined();
    expect(
      screen.getByRole("checkbox", { name: "Science News" }),
    ).toBeDefined();
  });
  it("filters projected publications by title or valid handle while preserving hidden selections", async () => {
    const onCreate = mock(async () => undefined);
    const science = "at://did:plc:publisher/site.standard.publication/science";
    const local = "at://did:plc:author/site.standard.publication/local";
    mount({
      onCreate,
      onResolveCreator: async () => ({ did: "did:plc:creator" }),
      publications: [
        {
          publicationId: science,
          title: "Science News",
          authorDid: "did:plc:publisher",
          authorHandle: "did:plc:publisher",
        },
        {
          publicationId: local,
          title: "Local News",
          authorDid: "did:plc:author",
          authorHandle: "local.example",
        },
      ],
    });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    fireEvent.change(screen.getByRole("textbox", { name: "List Name" }), {
      target: { value: "Reading" },
    });
    fireEvent.click(screen.getByRole("checkbox", { name: "Science News" }));
    const filter = screen.getByRole("searchbox", {
      name: "Filter Publications",
    });
    fireEvent.change(filter, { target: { value: "LOCAL.EXAMPLE" } });
    expect(screen.queryByRole("checkbox", { name: "Science News" })).toBeNull();
    fireEvent.click(screen.getByRole("checkbox", { name: /Local News/ }));
    expect(screen.getByText("2 Selected")).toBeDefined();
    fireEvent.change(filter, { target: { value: "missing" } });
    expect(screen.getByText("No Matching Publications.")).toBeDefined();
    expect(onCreate).not.toHaveBeenCalled();
    fireEvent.change(filter, { target: { value: "science" } });
    expect(
      (
        screen.getByRole("checkbox", {
          name: "Science News",
        }) as HTMLInputElement
      ).checked,
    ).toBe(true);
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    await waitFor(() =>
      expect(onCreate).toHaveBeenCalledWith({
        name: "Reading",
        publications: [science, local],
        users: [],
      }),
    );
  });
  it("retains creation fields on failure and resets them on reopening", async () => {
    const onCreate = mock(async () => {
      throw new Error("Sign Out And Sign In Again To Enable Creating Lists.");
    });
    mount({
      onCreate,
      onResolveCreator: async () => ({ did: "did:plc:creator" }),
    });
    const openCreate = () => {
      fireEvent.click(screen.getByRole("button", { name: "Add List" }));
      fireEvent.click(
        within(screen.getByRole("dialog")).getByRole("button", {
          name: "Create List",
        }),
      );
    };
    openCreate();
    const input = screen.getByRole("textbox", { name: "List Name" });
    fireEvent.change(input, { target: { value: "Research" } });
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "Sign Out And Sign In Again",
      ),
    );
    expect((input as HTMLInputElement).value).toBe("Research");
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Cancel",
      }),
    );
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    openCreate();
    expect(
      (screen.getByRole("textbox", { name: "List Name" }) as HTMLInputElement)
        .value,
    ).toBe("");
  });
  it("deduplicates resolved creator accounts and allows removal before creating", async () => {
    const onCreate = mock(async () => undefined);
    mount({
      onCreate,
      onResolveCreator: async () => ({
        did: "did:plc:creator",
        handle: "creator.test",
      }),
    });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    for (const input of ["creator.test", "did:plc:creator"]) {
      fireEvent.change(
        screen.getByRole("textbox", { name: "Creator Account" }),
        { target: { value: input } },
      );
      fireEvent.click(screen.getByRole("button", { name: "Add Creator" }));
      await waitFor(() =>
        expect(
          (
            screen.getByRole("textbox", {
              name: "Creator Account",
            }) as HTMLInputElement
          ).value,
        ).toBe(""),
      );
    }
    expect(screen.getAllByText("@creator.test")).toHaveLength(1);
    fireEvent.click(
      screen.getByRole("button", { name: "Remove creator.test" }),
    );
    fireEvent.change(screen.getByRole("textbox", { name: "List Name" }), {
      target: { value: "Empty List" },
    });
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    await waitFor(() =>
      expect(onCreate).toHaveBeenCalledWith({
        name: "Empty List",
        publications: [],
        users: [],
      }),
    );
  });
  it("validates list text limits before any write and preserves creator resolution errors", async () => {
    const onCreate = mock(async () => undefined);
    mount({
      onCreate,
      onResolveCreator: async () => {
        throw new Error("Creator Not Found");
      },
    });
    fireEvent.click(screen.getByRole("button", { name: "Add List" }));
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    fireEvent.change(screen.getByRole("textbox", { name: "Creator Account" }), {
      target: { value: "missing.test" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Add Creator" }));
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "Creator Not Found",
      ),
    );
    expect(
      (
        screen.getByRole("textbox", {
          name: "Creator Account",
        }) as HTMLInputElement
      ).value,
    ).toBe("missing.test");
    fireEvent.change(screen.getByRole("textbox", { name: "List Name" }), {
      target: { value: "x".repeat(65) },
    });
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain("64 characters"),
    );
    expect(onCreate).not.toHaveBeenCalled();
  });
  it("copies the official share link only after an explicit menu action", async () => {
    const descriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    const writeText = mock(async () => undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
    try {
      mount();
      expect(writeText).not.toHaveBeenCalled();
      fireEvent.click(
        screen.getByRole("button", { name: "More Actions For Technology" }),
      );
      fireEvent.click(
        await screen.findByRole("menuitem", { name: "Copy Link" }),
      );
      await waitFor(() =>
        expect(screen.getByRole("status").textContent).toBe(
          "List Link Copied.",
        ),
      );
      expect(writeText).toHaveBeenCalledWith(
        "https://standard-reader.app/l/did%3Aplc%3Aalice/example",
      );
    } finally {
      if (descriptor) Object.defineProperty(navigator, "clipboard", descriptor);
      else Reflect.deleteProperty(navigator, "clipboard");
    }
  });
  it("reports clipboard failures without mutating or removing the list", async () => {
    const descriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async () => {
          throw new Error("Clipboard Permission Denied");
        },
      },
    });
    const onRemove = mock(async () => undefined);
    try {
      mount({ onRemove });
      fireEvent.contextMenu(screen.getByRole("button", { name: "Technology" }));
      fireEvent.click(
        await screen.findByRole("menuitem", { name: "Copy Link" }),
      );
      await waitFor(() =>
        expect(screen.getByRole("alert").textContent).toContain(
          "Clipboard Permission Denied",
        ),
      );
      expect(onRemove).not.toHaveBeenCalled();
      expect(screen.getByRole("button", { name: "Technology" })).toBeDefined();
    } finally {
      if (descriptor) Object.defineProperty(navigator, "clipboard", descriptor);
      else Reflect.deleteProperty(navigator, "clipboard");
    }
  });
  it("ignores a completed creation after cancelling and reopening the form", async () => {
    let finish!: () => void;
    const onCreate = mock(
      () =>
        new Promise<void>((resolve) => {
          finish = resolve;
        }),
    );
    mount({
      onCreate,
      onResolveCreator: async () => ({ did: "did:plc:creator" }),
    });
    const openCreate = () => {
      fireEvent.click(screen.getByRole("button", { name: "Add List" }));
      fireEvent.click(
        within(screen.getByRole("dialog")).getByRole("button", {
          name: "Create List",
        }),
      );
    };
    openCreate();
    fireEvent.change(screen.getByRole("textbox", { name: "List Name" }), {
      target: { value: "First List" },
    });
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Create List",
      }),
    );
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", {
        name: "Cancel",
      }),
    );
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    openCreate();
    fireEvent.change(screen.getByRole("textbox", { name: "List Name" }), {
      target: { value: "Second List" },
    });
    finish();
    await waitFor(() =>
      expect(
        (screen.getByRole("textbox", { name: "List Name" }) as HTMLInputElement)
          .value,
      ).toBe("Second List"),
    );
    expect(onCreate).toHaveBeenCalledTimes(1);
  });
  it("requires a distinct confirmation to delete an owned original and retains deletion failures", async () => {
    const onDelete = mock(async () => {
      throw new Error("Deletion Failed");
    });
    const onRemove = mock(async () => undefined);
    mount({
      lists: [{ ...base.lists[0]!, owned: true, saved: true }],
      onDelete,
      onRemove,
    });
    fireEvent.click(
      screen.getByRole("button", { name: "More Actions For Technology" }),
    );
    expect(
      await screen.findByRole("menuitem", { name: "Copy Link" }),
    ).toBeDefined();
    expect(screen.queryByRole("menuitem", { name: "Remove List" })).toBeNull();
    fireEvent.click(screen.getByRole("menuitem", { name: "Delete List" }));
    expect(onDelete).not.toHaveBeenCalled();
    const confirmation = screen.getByRole("group", {
      name: "Confirm List Deletion",
    });
    expect(confirmation.textContent).toContain("original public list");
    fireEvent.click(
      within(confirmation).getByRole("button", { name: "Delete List" }),
    );
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "Deletion Failed",
      ),
    );
    expect(onDelete).toHaveBeenCalledWith(uri);
    expect(onRemove).not.toHaveBeenCalled();
    expect(
      screen.getByRole("group", { name: "Confirm List Deletion" }),
    ).toBeDefined();
  });
  it("keeps the truthful cleanup error after the original list was already deleted", async () => {
    const onDelete = mock(async () => {
      throw Object.assign(
        new Error(
          "The List Was Deleted, But Its Saved Reference Could Not Be Removed. Refresh Lists To Try Again.",
        ),
        { originalDeleted: true },
      );
    });
    mount({ lists: [{ ...base.lists[0]!, owned: true }], onDelete });
    fireEvent.contextMenu(screen.getByRole("button", { name: "Technology" }));
    fireEvent.click(
      await screen.findByRole("menuitem", { name: "Delete List" }),
    );
    fireEvent.click(
      within(
        screen.getByRole("group", { name: "Confirm List Deletion" }),
      ).getByRole("button", { name: "Delete List" }),
    );
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "The List Was Deleted",
      ),
    );
    expect(
      screen.queryByRole("group", { name: "Confirm List Deletion" }),
    ).toBeNull();
  });
  for (const saved of [true, false]) {
    it(`highlights the entire selected ${saved ? "saved" : "owned"} list row with a single purple surface`, () => {
      mount({ lists: [{ ...base.lists[0]!, saved, owned: !saved }] });
      const button = screen.getByRole("button", { name: "Technology" });
      const row = button.closest("li")!;
      expect(row.className).toContain("bg-[var(--purple-surface)]");
      expect(row.className).toContain("text-[var(--purple-foreground)]");
      expect(row.className).toContain(
        "[box-shadow:var(--purple-sidebar-selected)]",
      );
      expect(button.className).toContain("data-active:[box-shadow:none]");
      expect(button.className).toContain("focus-visible:ring-2");
      if (saved) {
        const actions = screen.getByRole("button", {
          name: "More Actions For Technology",
        });
        expect(actions.closest("li")).toBe(row);
        expect(actions.className).toContain("text-inherit");
        expect(actions.className).toContain("focus-visible:ring-2");
      }
    });
  }
  for (const saved of [true, false]) {
    it(`owns hover and focus highlighting across the unselected ${saved ? "saved" : "owned"} row`, () => {
      mount({
        selectedUri: null,
        lists: [{ ...base.lists[0]!, saved, owned: !saved }],
      });
      const button = screen.getByRole("button", { name: "Technology" });
      const row = button.closest("li")!;
      expect(row.className).not.toContain("bg-[var(--purple-surface)]");
      expect(row.className).toContain("hover:bg-sidebar-accent/65");
      expect(row.className).toContain("focus-within:bg-sidebar-accent/65");
      expect(button.className).toContain("hover:bg-transparent");
      expect(button.className).toContain("text-inherit");
      expect(button.className).toContain("focus-visible:ring-2");
      if (saved) {
        const actions = screen.getByRole("button", {
          name: "More Actions For Technology",
        });
        expect(actions.closest("li")).toBe(row);
        expect(actions.className).toContain("hover:bg-transparent");
        expect(actions.className).toContain("text-inherit");
        expect(actions.className).toContain("focus-visible:ring-2");
      }
    });
  }
  it("keeps the full unselected row highlighted while More Actions is open", async () => {
    mount({ selectedUri: null });
    const actions = screen.getByRole("button", {
      name: "More Actions For Technology",
    });
    const row = actions.closest("li")!;
    fireEvent.click(actions);
    await screen.findByRole("menuitem", { name: "Remove List" });
    expect(actions.hasAttribute("data-popup-open")).toBe(true);
    expect(row.className).toContain(
      "has-[[data-popup-open]]:bg-sidebar-accent/70",
    );
  });
  it("keeps the full unselected row highlighted while its context menu is open", async () => {
    mount({ selectedUri: null });
    const button = screen.getByRole("button", { name: "Technology" });
    const row = button.closest("li")!;
    fireEvent.contextMenu(button);
    await screen.findByRole("menuitem", { name: "Remove List" });
    expect(row.hasAttribute("data-popup-open")).toBe(true);
    expect(row.className).toContain("data-popup-open:bg-sidebar-accent/70");
  });
});
