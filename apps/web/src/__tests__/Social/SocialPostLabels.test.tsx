import { afterAll, afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { interpretLabelValueDefinition, type AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import type { SocialModerationOpts } from "@/lib/socialModerationTypes";
import { SocialPostLabels } from "@/components/Social/SocialPostLabels";

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

const originalAppEnv = process.env.NEXT_PUBLIC_APP_ENV;
afterEach(() => {
  cleanup();
  if (originalAppEnv === undefined) delete process.env.NEXT_PUBLIC_APP_ENV;
  else process.env.NEXT_PUBLIC_APP_ENV = originalAppEnv;
});

const did = "did:plc:trustedlabeler";
const description = `<script>alert('fixture')</script>\n<img src=x onerror=alert(1)>\n${"Complete author-safe description 🌿 ".repeat(100)}`;
const definitions = ["verified", "illustration", "community", "context"].map((identifier, index) =>
  interpretLabelValueDefinition({
    identifier, severity: "inform", blurs: "none", defaultSetting: "ignore",
    locales: [
      { lang: "en", name: `Label ${index + 1}`, description: index === 0 ? description : `Description ${index + 1}` },
      { lang: "fr", name: `Étiquette ${index + 1}`, description: `Description française ${index + 1}` },
    ],
  }, did),
);
const moderation: ModerationOpts = {
  userDid: "did:plc:viewer",
  prefs: { adultContentEnabled: true, labels: {}, labelers: [{ did, labels: {} }], mutedWords: [], hiddenPosts: [] },
  labelDefs: { [did]: definitions },
};
const uri = "at://did:plc:author/app.bsky.feed.post/a";
const post: AppBskyFeedDefs.PostView = {
  uri, cid: "bafyreia", author: { did: "did:plc:author", handle: "author.test" },
  indexedAt: "2026-10-10T00:00:00Z",
  record: { $type: "app.bsky.feed.post", text: "Fixture", createdAt: "2026-10-10T00:00:00Z" },
  labels: definitions.map(definition => ({ src: did, uri, val: definition.identifier, cts: "2026-10-10T00:00:00Z" })),
};

describe("Social Post Labels Dialog", () => {
  it("uses singular wording for one additional label and opens all three labels", async () => {
    render(<SocialPostLabels post={{ ...post, labels: post.labels?.slice(0, 3) }} moderation={moderation} />);
    expect(screen.queryByRole("button", { name: "+1 Labels" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "+1 Label" }));
    const dialog = await screen.findByRole("dialog", { name: "Post Labels" });
    expect(within(dialog).getAllByRole("heading", { level: 3 })).toHaveLength(3);
  });

  it.each(["prod", "production", "local", "dev", "test"])("shows identity and avatars with environment-scoped DID in %s", async (env) => {
    process.env.NEXT_PUBLIC_APP_ENV = env;
    const avatar = "https://images.example/labeler.png";
    const withProfile: SocialModerationOpts = {
      ...moderation,
      labelerProfiles: { [did]: { displayName: "Community Labeler", handle: "labels.example" } },
      labelerAvatars: { [did]: avatar },
    };
    render(<SocialPostLabels post={post} moderation={withProfile} />);
    fireEvent.click(screen.getByRole("button", { name: "+2 Labels" }));
    const dialog = await screen.findByRole("dialog", { name: "Post Labels" });
    expect(within(dialog).getAllByText("Community Labeler")).toHaveLength(4);
    expect(within(dialog).getAllByText("@labels.example")).toHaveLength(4);
    expect(dialog.querySelectorAll(`img[src="${avatar}"]`)).toHaveLength(4);
    expect(within(dialog).queryAllByText(did)).toHaveLength(env === "prod" || env === "production" ? 0 : 4);
    const image = dialog.querySelector("img")!;
    fireEvent.error(image);
    expect(dialog.querySelectorAll("img")).toHaveLength(3);
  });

  it("keeps unresolved labeler DIDs hidden in production", async () => {
    process.env.NEXT_PUBLIC_APP_ENV = "prod";
    render(<SocialPostLabels post={post} moderation={moderation} />);
    fireEvent.click(screen.getByRole("button", { name: "+2 Labels" }));
    const dialog = await screen.findByRole("dialog", { name: "Post Labels" });
    expect(within(dialog).getAllByText("Unknown Labeler")).toHaveLength(4);
    expect(dialog.textContent).not.toContain(did);
  });

  it("falls back to the handle when the display name is absent", async () => {
    process.env.NEXT_PUBLIC_APP_ENV = "prod";
    render(<SocialPostLabels post={post} moderation={{ ...moderation, labelerProfiles: { [did]: { handle: "labels.example" } } }} />);
    fireEvent.click(screen.getByRole("button", { name: "+2 Labels" }));
    const dialog = await screen.findByRole("dialog", { name: "Post Labels" });
    expect(within(dialog).getAllByText("labels.example")).toHaveLength(4);
    expect(within(dialog).getAllByText("@labels.example")).toHaveLength(4);
    expect(dialog.textContent).not.toContain(did);
  });

  it("collapses after two badges and shows every safe description and source independently of post navigation", async () => {
    const clickPost = mock(() => undefined);
    render(<div onClick={clickPost}><SocialPostLabels post={post} moderation={moderation} /></div>);
    expect(screen.getByRole("button", { name: "Label 1" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Label 2" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Label 3" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "+2 Labels" }));
    const dialog = await screen.findByRole("dialog", { name: "Post Labels" });
    expect(clickPost).not.toHaveBeenCalled();
    expect(within(dialog).getAllByRole("heading", { level: 3 })).toHaveLength(4);
    expect(within(dialog).getByText(description, { exact: true, normalizer: value => value }).textContent).toBe(description);
    expect(dialog.querySelector("script, img")).toBeNull();
    expect(within(dialog).getAllByText("Unknown Labeler")).toHaveLength(4);
    expect(within(dialog).getByRole("link", { name: "Manage Labelers" }).getAttribute("href")).toBe("/me/settings");
  });

  it("opens a localized description directly from a visible badge", async () => {
    const original = Object.getOwnPropertyDescriptor(navigator, "languages");
    Object.defineProperty(navigator, "languages", { configurable: true, value: ["fr-CA", "en"] });
    try {
      render(<SocialPostLabels post={post} moderation={moderation} />);
      fireEvent.click(screen.getByRole("button", { name: "Étiquette 1" }));
      const dialog = await screen.findByRole("dialog", { name: "Post Labels" });
      expect(within(dialog).getByText("Description française 1")).toBeTruthy();
      expect(within(dialog).getByRole("heading", { name: "Étiquette 4" })).toBeTruthy();
      expect(within(dialog).queryByText(description)).toBeNull();
    } finally {
      if (original) Object.defineProperty(navigator, "languages", original);
      else Reflect.deleteProperty(navigator, "languages");
    }
  });
});
