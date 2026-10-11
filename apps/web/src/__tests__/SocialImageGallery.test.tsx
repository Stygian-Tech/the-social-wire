import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  mock,
} from "bun:test";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { renderToStaticMarkup } from "react-dom/server";
import { SocialImageGallery } from "@/components/Social/SocialImageGallery";
import { SocialPostEmbed } from "@/components/Social/SocialPostEmbed";
import type { ModerationOpts } from "@atproto/api";

const browserGlobals = [
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
] as const;
const originalBrowserGlobals = browserGlobals.map(
  (name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)] as const,
);
beforeAll(() => {
  Object.defineProperty(globalThis, "requestAnimationFrame", {
    configurable: true,
    value: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(performance.now()), 0),
  });
  Object.defineProperty(globalThis, "cancelAnimationFrame", {
    configurable: true,
    value: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle),
  });
  Object.defineProperty(globalThis, "getComputedStyle", {
    configurable: true,
    value: window.getComputedStyle.bind(window),
  });
});
afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 10));
  for (const [name, descriptor] of originalBrowserGlobals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
});

const image = {
  thumb: "https://publisher.example/thumb.jpg",
  fullsize: "https://publisher.example/original.jpg",
  alt: "A portrait",
  aspectRatio: { width: 600, height: 1200 },
};
const originalFetch = globalThis.fetch;
afterEach(() => {
  cleanup();
  globalThis.fetch = originalFetch;
});
function imageFetch() {
  globalThis.fetch = Object.assign(
    mock(
      async () =>
        new Response("png bytes", { headers: { "content-type": "image/png" } }),
    ),
    { preconnect: originalFetch.preconnect },
  ) as typeof fetch;
}

function pointer(target: Element, type: string, x: number, y: number, id = 1) {
  const event = new window.Event(type, { bubbles: true, cancelable: true });
  for (const [key, value] of Object.entries({ clientX: x, clientY: y, pointerId: id, pointerType: "touch", button: 0 })) Object.defineProperty(event, key, { value });
  fireEvent(target, event);
  return event;
}
const secondImage = { ...image, thumb: "https://publisher.example/two.jpg", fullsize: "https://publisher.example/two-original.jpg", alt: "Second Photo" };

describe("Social Image Gallery", () => {
  it("navigates one uncropped photo at a time using arrows, dots, and keyboard", () => {
    render(<SocialImageGallery images={[image, secondImage]} />);
    expect(screen.getAllByRole("img")).toHaveLength(1);
    expect(screen.getByText("1 / 2")).toBeTruthy();
    expect((screen.getByRole("button", { name: "Previous Photo" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Next Photo" }));
    expect(screen.getByRole("img").getAttribute("src")).toBe(secondImage.thumb);
    expect(screen.getByRole("button", { name: "Show Photo 2" }).getAttribute("aria-pressed")).toBe("true");
    expect(screen.getByRole("button", { name: "View Image 2 Alt Text" })).toBeTruthy();
    fireEvent.keyDown(screen.getByRole("group", { name: "Post Images" }), { key: "ArrowLeft" });
    expect(screen.getByRole("img").getAttribute("src")).toBe(image.thumb);
    fireEvent.click(screen.getByRole("button", { name: "Show Photo 2" }));
    fireEvent.keyDown(screen.getByRole("group", { name: "Post Images" }), { key: "Home" });
    expect(screen.getByText("1 / 2")).toBeTruthy();
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("swipes horizontally without stealing vertical scroll or opening the viewer after dragging", () => {
    render(<SocialImageGallery images={[image, secondImage]} />);
    const button = screen.getByRole("button", { name: "Open Image 1: A portrait" });
    const container = button.parentElement!;
    const capture = mock(() => {});
    Object.defineProperty(container, "setPointerCapture", { value: capture });
    expect(container.style.touchAction).toBe("pan-y");
    pointer(button, "pointerdown", 150, 50);
    const vertical = pointer(container, "pointermove", 145, 120);
    pointer(container, "pointerup", 145, 120);
    expect(vertical.defaultPrevented).toBe(false);
    expect(capture).not.toHaveBeenCalled();
    expect(screen.getByText("1 / 2")).toBeTruthy();
    pointer(button, "pointerdown", 150, 50);
    pointer(button, "pointerdown", 140, 60, 2);
    pointer(container, "pointermove", 60, 55, 2);
    pointer(container, "pointerup", 60, 55, 2);
    expect(screen.getByText("1 / 2")).toBeTruthy();
    pointer(button, "pointerdown", 150, 50);
    const horizontal = pointer(container, "pointermove", 60, 55);
    pointer(container, "pointerup", 60, 55);
    expect(horizontal.defaultPrevented).toBe(true);
    expect(capture).toHaveBeenCalledWith(1);
    expect(screen.getByText("2 / 2")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Open Image 2: Second Photo" }));
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("navigates the full-screen carousel at normal zoom and keeps arrow panning when zoomed", async () => {
    imageFetch();
    render(<SocialImageGallery images={[image, secondImage]} />);
    fireEvent.click(screen.getByRole("button", { name: "Open Image 1: A portrait" }));
    let dialog = await screen.findByRole("dialog");
    fireEvent.keyDown(within(dialog).getByRole("group", { name: "Image Viewer" }), { key: "ArrowRight" });
    await waitFor(() => expect(within(screen.getByRole("dialog")).getByRole("img").getAttribute("src")).toBe(secondImage.fullsize));
    dialog = screen.getByRole("dialog");
    fireEvent.click(within(dialog).getByRole("button", { name: "Zoom In" }));
    fireEvent.keyDown(within(dialog).getByRole("group", { name: "Image Viewer" }), { key: "ArrowLeft" });
    expect(within(dialog).getByRole("img").getAttribute("src")).toBe(secondImage.fullsize);
    fireEvent.click(within(dialog).getByRole("button", { name: "Reset Zoom" }));
    const viewport = within(dialog).getByRole("group", { name: "Image Viewer" });
    pointer(viewport, "pointerdown", 50, 50);
    pointer(viewport, "pointermove", 150, 55);
    pointer(viewport, "pointerup", 150, 55);
    await waitFor(() => expect(within(screen.getByRole("dialog")).getByRole("img").getAttribute("src")).toBe(image.fullsize));
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(screen.getByText("1 / 2")).toBeTruthy();
  });

  it("fills a single column with uncropped independently rounded intrinsic-ratio images", () => {
    const one = renderToStaticMarkup(<SocialImageGallery images={[image]} />);
    expect(one).toContain("Post Images");
    expect(one).not.toContain("Next Photo");
    expect(one).not.toContain("grid-cols-2");
    expect(one).toContain('width="600" height="1200"');
    expect(one).toContain("h-auto w-full");
    expect(one).not.toContain("object-cover");
    expect(one).not.toContain("max-h-96");
    const many = renderToStaticMarkup(
      <SocialImageGallery
        images={[
          image,
          { ...image, thumb: "https://publisher.example/two.jpg" },
        ]}
      />,
    );
    expect(many).toContain("carousel");
    expect(many).toContain("Next Photo");
    expect(many.match(/<img /g)?.length).toBe(1);
  });
  it("opens the full-size dialog, resets zoom on reopen and does not navigate the post", async () => {
    imageFetch();
    const postClick = mock(() => undefined);
    await act(async () => {
      render(
        <div onClick={postClick}>
          <SocialImageGallery images={[image]} />
        </div>,
      );
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Open Image 1: A portrait" }),
    );
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByRole("img").getAttribute("src")).toBe(
      image.fullsize,
    );
    expect(postClick).not.toHaveBeenCalled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Zoom In" }));
    expect(within(dialog).getByText("150%")).toBeTruthy();
    fireEvent.click(within(dialog).getByRole("button", { name: "Reset Zoom" }));
    expect(within(dialog).getByText("100%")).toBeTruthy();
    fireEvent.wheel(within(dialog).getByRole("img").parentElement!, {
      deltaY: -200,
      clientX: 20,
      clientY: 20,
    });
    expect(within(dialog).getByText("149%")).toBeTruthy();
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    fireEvent.click(
      screen.getByRole("button", { name: "Open Image 1: A portrait" }),
    );
    expect(
      within(await screen.findByRole("dialog")).getByText("100%"),
    ).toBeTruthy();
  });
  it("shows badges only for described images and opens alt text independently of the image viewer", async () => {
    imageFetch();
    const postClick = mock(() => undefined);
    render(<div onClick={postClick}><SocialImageGallery images={[
      image,
      { ...image, thumb: "https://publisher.example/blank.jpg", alt: " \n\t" },
    ]} /></div>);
    const badge = screen.getByRole("button", { name: "View Image 1 Alt Text" });
    expect(screen.queryByRole("button", { name: "View Image 2 Alt Text" })).toBeNull();
    expect(badge.parentElement?.tagName).toBe("DIV");
    fireEvent.click(badge);
    const dialog = await screen.findByRole("dialog", { name: "Alt Text" });
    expect(within(dialog).getByText(image.alt)).toBeTruthy();
    expect(within(dialog).queryByRole("img")).toBeNull();
    expect(within(dialog).queryByRole("button", { name: "Zoom In" })).toBeNull();
    expect(screen.getAllByRole("dialog")).toHaveLength(1);
    expect(globalThis.fetch).not.toHaveBeenCalled();
    expect(postClick).not.toHaveBeenCalled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    fireEvent.click(screen.getByRole("button", { name: "Open Image 1: A portrait" }));
    const viewer = await screen.findByRole("dialog");
    expect(within(viewer).getByRole("img").getAttribute("src")).toBe(image.fullsize);
  });
  it("reports unsupported clipboard rather than claiming an image was copied", async () => {
    imageFetch();
    const original = Object.getOwnPropertyDescriptor(
      globalThis,
      "ClipboardItem",
    );
    Reflect.deleteProperty(globalThis, "ClipboardItem");
    try {
      render(<SocialImageGallery images={[image]} />);
      fireEvent.click(
        screen.getByRole("button", { name: "Open Image 1: A portrait" }),
      );
      const dialog = await screen.findByRole("dialog");
      const button = within(dialog).getByRole("button", { name: "Copy Image" });
      await waitFor(() =>
        expect((button as HTMLButtonElement).disabled).toBe(false),
      );
      fireEvent.click(button);
      expect((await within(dialog).findByRole("alert")).textContent).toContain(
        "unavailable in this browser",
      );
      expect(within(dialog).queryByText("Image copied.")).toBeNull();
    } finally {
      if (original)
        Object.defineProperty(globalThis, "ClipboardItem", original);
    }
  });
  it("aborts original loading when the dialog closes", async () => {
    let signal: AbortSignal | undefined;
    globalThis.fetch = Object.assign(
      mock(async (_url: unknown, init?: RequestInit) => {
        signal = init?.signal as AbortSignal;
        return await new Promise<Response>(() => {});
      }),
      { preconnect: originalFetch.preconnect },
    ) as typeof fetch;
    render(<SocialImageGallery images={[image]} />);
    fireEvent.click(
      screen.getByRole("button", { name: "Open Image 1: A portrait" }),
    );
    const dialog = await screen.findByRole("dialog");
    expect(signal?.aborted).toBe(false);
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(signal?.aborted).toBe(true));
  });
  it("sizes video by its declared ratio with native controls and no redundant link", () => {
    const moderation: ModerationOpts = {
      userDid: "did:plc:viewer",
      prefs: {
        adultContentEnabled: false,
        labels: {},
        labelers: [],
        mutedWords: [],
        hiddenPosts: [],
      },
    };
    const html = renderToStaticMarkup(
      <SocialPostEmbed
        moderation={moderation}
        embed={{
          $type: "app.bsky.embed.video#view",
          cid: "bafyreia",
          playlist: "https://video.example/video.m3u8",
          aspectRatio: { width: 1080, height: 1920 },
        }}
      />,
    );
    expect(html).toContain("aspect-ratio:1080 / 1920");
    expect(html).toContain('width="1080" height="1920"');
    expect(html).toContain("controls");
    expect(html).not.toContain("Open Video");
    expect(html).not.toContain("max-h-96");
  });
});
