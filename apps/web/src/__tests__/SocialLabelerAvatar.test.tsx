import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render } from "@testing-library/react";
import * as Image from "@/hooks/useCachedImageUrl";
import { SocialLabelerAvatar } from "@/components/Social/SocialLabelerAvatar";

afterEach(cleanup);

describe("Labeler avatars", () => {
  it("shows a cached avatar and restores the tag icon if the image fails", () => {
    const cache = spyOn(Image, "useCachedImageUrl").mockImplementation(source => ({ objectUrl: source ?? undefined, failed: false }));
    try {
      const view = render(<SocialLabelerAvatar avatar="https://images.example/labeler.png" />);
      const image = view.container.querySelector("img")!;
      expect(image.getAttribute("src")).toBe("https://images.example/labeler.png");
      expect(image.getAttribute("alt")).toBe("");
      expect(view.container.querySelector("svg")).toBeNull();
      fireEvent.error(image);
      expect(view.container.querySelector("img")).toBeNull();
      expect(view.container.querySelector("svg")).not.toBeNull();
      view.rerender(<SocialLabelerAvatar avatar="https://images.example/new-labeler.png" />);
      expect(view.container.querySelector("img")?.getAttribute("src")).toBe("https://images.example/new-labeler.png");
    } finally { cache.mockRestore(); }
  });

  it("uses the tag fallback for missing, unsafe, and failed cached avatars", () => {
    const cache = spyOn(Image, "useCachedImageUrl").mockImplementation(source => ({ objectUrl: source ?? undefined, failed: source === "https://images.example/failed.png" }));
    try {
      for (const avatar of [undefined, "javascript:alert(1)", "https://images.example/failed.png"]) {
        const view = render(<SocialLabelerAvatar avatar={avatar} />);
        expect(view.container.querySelector("img")).toBeNull();
        expect(view.container.querySelector("svg")).not.toBeNull();
        view.unmount();
      }
    } finally { cache.mockRestore(); }
  });
});
