import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as gateway from "@/lib/socialWireGatewayClient";
import * as nextImage from "next/image";
import type { ImageProps } from "next/image";
import { PodcastArtwork } from "@/components/Podcasts/PodcastArtwork";

const restores: (() => void)[] = [];
beforeEach(() => {
  // Other suites replace next/image globally. Restore this scoped, prop-preserving spy after each test.
  const imageSpy = spyOn(nextImage, "default").mockImplementation((({ src, alt, width, height, style, onError, className }: ImageProps) =>
    // eslint-disable-next-line @next/next/no-img-element
    <img src={typeof src === "string" ? src : ""} alt={alt} width={width} height={height} style={style} onError={onError} className={className} />) as unknown as typeof nextImage.default);
  restores.push(() => imageSpy.mockRestore());
});
afterEach(() => {
  cleanup();
  for (const restore of restores.splice(0).reverse()) restore();
});

it("keeps non-square chapter artwork and episode fallbacks inside the thumbnail bounds", () => {
  render(<PodcastArtwork src="https://publisher.test/portrait.jpg" fallbackSources={["https://publisher.test/episode.jpg"]} alt="Chapter Artwork: Intro" size={40} />);
  const image = screen.getByRole("img", { name: "Chapter Artwork: Intro" }) as HTMLImageElement;
  expect(image.style.width).toBe("40px");
  expect(image.style.height).toBe("40px");
  fireEvent.error(image);
  expect(image.src).toBe("https://publisher.test/episode.jpg");
  expect(image.style.width).toBe("40px");
  expect(image.style.height).toBe("40px");
  fireEvent.error(image);
  const placeholder = screen.getByRole("img", { name: "Chapter Artwork: Intro" }) as HTMLElement;
  expect(placeholder.tagName).toBe("SPAN");
  expect(placeholder.style.width).toBe("40px");
  expect(placeholder.style.height).toBe("40px");
});

it("keeps authenticated chapter artwork in the same bounds after loading", async () => {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const authSpy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: oauth.did }, getOAuthSession: () => oauth } as ReturnType<typeof auth.useAuth>);
  const fetchSpy = spyOn(gateway, "gatewayFetch").mockResolvedValue(new Response(new Blob(["image"], { type: "image/png" })));
  const createSpy = spyOn(URL, "createObjectURL").mockReturnValue("blob:chapter-artwork");
  const revokeSpy = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  restores.push(() => authSpy.mockRestore(), () => fetchSpy.mockRestore(), () => createSpy.mockRestore(), () => revokeSpy.mockRestore());
  const view = render(<PodcastArtwork src="/v1/podcasts/image?episodeId=private&kind=chapter&index=0" alt="Private Chapter Artwork" size={48} />);
  await waitFor(() => expect(view.container.querySelector("img")).not.toBeNull());
  const loaded = view.container.querySelector("img")!;
  expect(loaded.src).toBe("blob:chapter-artwork");
  expect(loaded.style.width).toBe("48px");
  expect(loaded.style.height).toBe("48px");
  expect(loaded.alt).toBe("Private Chapter Artwork");
  view.unmount();
  expect(revokeSpy).toHaveBeenCalledWith("blob:chapter-artwork");
});
