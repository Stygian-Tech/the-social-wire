import { afterEach, describe, expect, it, spyOn } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as client from "@/lib/podcasts/client";
import * as player from "@/components/Podcasts/PodcastPlayerProvider";
import { PodcastClips } from "@/components/Podcasts/PodcastClips";
const restores: (() => void)[] = [];
afterEach(() => {
  cleanup();
  for (const restore of restores.splice(0).reverse()) restore();
});
describe("Podcast clip caption exports", () => {
  for (const includeCaptions of [true, false]) {
    it(`prepares exports with publisher captions ${includeCaptions ? "enabled by default" : "explicitly disabled"}`, async () => {
      const oauth = {} as OAuthSession;
      const getOAuthSession = () => oauth;
      const authSpy = spyOn(auth, "useAuth").mockReturnValue({
        session: { did: "did:plc:viewer" },
        getOAuthSession,
      } as ReturnType<typeof auth.useAuth>);
      const playerSpy = spyOn(player, "usePodcastPlayer").mockReturnValue({
        duration: 120,
        position: 0,
        playing: false,
      } as ReturnType<typeof player.usePodcastPlayer>);
      const requests = spyOn(client, "podcastRequest").mockResolvedValue({
        clips: [],
      });
      restores.push(
        () => authSpy.mockRestore(),
        () => playerSpy.mockRestore(),
        () => requests.mockRestore(),
      );
      render(
        <PodcastClips
          episode={{
            id: "episode",
            showId: "show",
            title: "Episode",
            audioUrl: "https://publisher.example/audio.mp3",
            durationSeconds: 120,
            publishedAt: "2026-10-04T12:00:00Z",
            transcripts: [],
          }}
        />,
      );
      const captions = screen.getByRole("checkbox", {
        name: /Include Captions/,
      }) as HTMLInputElement;
      expect(captions.checked).toBe(true);
      if (!includeCaptions) fireEvent.click(captions);
      fireEvent.click(screen.getByRole("button", { name: "Prepare Exports" }));
      await waitFor(() =>
        expect(requests).toHaveBeenCalledWith(
          oauth,
          "clips",
          "POST",
          expect.objectContaining({
            includeCaptions,
            startSeconds: 0,
            endSeconds: 30,
          }),
        ),
      );
    });
  }
});
