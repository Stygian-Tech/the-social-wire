import { afterEach, expect, it } from "bun:test";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { SocialComposePreview } from "@/components/Social/SocialComposePreview";

afterEach(() => { cleanup(); });

it("previews the native text that other clients will display", () => {
  const view = render(<SocialComposePreview text="**Bold** *Italic* `code`" />);
  const preview = screen.getByRole("region", { name: "Post Preview" });
  expect(preview.textContent).toBe("PreviewBold Italic code");
  expect(preview.querySelector("strong, em, code")).toBeNull();
  view.rerender(<SocialComposePreview text="[XBOX Labs](labs.xbox.com) is interesting" />);
  expect(preview.textContent).toBe("PreviewXBOX Labs is interesting");
  expect(preview.querySelector("a")?.getAttribute("href")).toBe("https://labs.xbox.com/");
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
