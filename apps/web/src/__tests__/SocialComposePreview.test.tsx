import { afterEach, expect, it } from "bun:test";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { SocialComposePreview } from "@/components/Social/SocialComposePreview";

afterEach(() => { cleanup(); });

it("renders formatting while drafting and updates as text changes", () => {
  const view = render(<SocialComposePreview text="**Bold** *Italic* `code`" />);
  const preview = screen.getByRole("region", { name: "Post Preview" });
  expect(preview.querySelector("strong")?.textContent).toBe("Bold");
  expect(preview.querySelector("em")?.textContent).toBe("Italic");
  expect(preview.querySelector("code")?.textContent).toBe("code");
  view.rerender(<SocialComposePreview text={"## Heading\n\n- Item\n\n> Quote"} />);
  expect(preview.querySelector("h2")?.textContent).toBe("Heading");
  expect(preview.querySelector("li")?.textContent).toBe("Item");
  expect(preview.querySelector("blockquote")?.textContent).toBe("Quote");
  expect(preview.querySelector("strong")).toBeNull();
});

it("previews safe links and hashtags without resolving mentions or executing HTML", () => {
  render(<SocialComposePreview text="🌎 https://example.com #news @alice.test <script>alert(1)</script> [Bad](javascript:alert(1))" />);
  const preview = screen.getByRole("region", { name: "Post Preview" });
  expect(preview.querySelectorAll("a")).toHaveLength(2);
  expect(preview.querySelector("a")?.getAttribute("href")).toBe("https://example.com/");
  expect(preview.querySelector("script")).toBeNull();
  expect(preview.textContent).toContain("@alice.test");
});

it("omits empty drafts and tolerates unfinished Markdown", async () => {
  const view = render(<SocialComposePreview text="**unfinished" />);
  expect(screen.getByRole("region").textContent).toContain("**unfinished");
  view.rerender(<SocialComposePreview text={"  \n"} />);
  await waitFor(() => expect(screen.queryByRole("region", { name: "Post Preview" })).toBeNull());
});
