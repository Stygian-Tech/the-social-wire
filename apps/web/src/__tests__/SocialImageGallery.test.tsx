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

describe("Social Image Gallery", () => {
  it("fills a single column with uncropped independently rounded intrinsic-ratio images", () => {
    const one = renderToStaticMarkup(<SocialImageGallery images={[image]} />);
    expect(one).toContain("grid-cols-1");
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
    expect(many).toContain("grid-cols-2 items-start");
    expect(many.match(/rounded-xl/g)?.length).toBe(2);
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
