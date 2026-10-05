import { afterEach, describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as atproto from "@/lib/atprotoClient";
import * as gateway from "@/lib/socialWireGatewayClient";
import {
  publishPodcastClip,
  writePodcastSubscription,
} from "@/lib/podcasts/client";
const oauth = {} as OAuthSession;
const restores: (() => void)[] = [];
afterEach(() => {
  for (const restore of restores.splice(0)) restore();
});
function mockAgent() {
  const writes: unknown[] = [];
  const putRecord = async (record: unknown) => {
    writes.push(record);
    return {
      data: {
        uri: "at://did:plc:viewer/app.thesocialwire.podcast.clip/clip-1",
      },
    };
  };
  const agent = spyOn(atproto, "createOAuthAgent").mockReturnValue({
    com: { atproto: { repo: { putRecord, deleteRecord: async () => ({}) } } },
  } as unknown as ReturnType<typeof atproto.createOAuthAgent>);
  restores.push(() => agent.mockRestore());
  return writes;
}
describe("Podcast public PDS records", () => {
  it("uses authoritative Skyreader collection source fields and a stable show reference", async () => {
    const writes = mockAgent();
    await writePodcastSubscription(oauth, "did:plc:viewer", {
      id: "show",
      title: "Protocol Show",
      sourceKind: "atproto",
      sourceUri: "at://did:plc:publisher/org.atpodcasting.podcast/show",
      episodeCollection: "org.atpodcasting.episode",
    });
    const record = (writes[0] as { record: Record<string, unknown> }).record;
    expect(record.sourceType).toBe("atproto.collection");
    expect(record.subjectDid).toBe("did:plc:publisher");
    expect(record.collectionNsid).toBe("org.atpodcasting.episode");
    expect(record.externalRef).toBe(
      "at://did:plc:publisher/org.atpodcasting.podcast/show",
    );
    expect(record.feedUrl).toBeUndefined();
  });
  it("retains RSS identity and its linked protocol show in the shared subscription", async () => {
    const writes = mockAgent();
    await writePodcastSubscription(oauth, "did:plc:viewer", {
      id: "show",
      title: "RSS Show",
      sourceKind: "rss",
      feedUrl: "https://podcast.example/rss",
      sourceUri: "at://did:plc:bridge/org.atpodcasting.podcast/show",
    });
    const record = (writes[0] as { record: Record<string, unknown> }).record;
    expect(record.feedUrl).toBe("https://podcast.example/rss");
    expect(record.sourceType).toBe("rss");
    expect(record.externalRef).toContain("did:plc:bridge");
  });
  it("publishes millisecond bounds and public assets, then verifies the PDS record through AppView", async () => {
    const writes = mockAgent();
    const fetch = spyOn(gateway, "gatewayFetch").mockResolvedValue(
      Response.json({
        clipId: "clip-1",
        uri: "at://did:plc:viewer/app.thesocialwire.podcast.clip/clip-1",
      }),
    );
    restores.push(() => fetch.mockRestore());
    await publishPodcastClip(
      oauth,
      "did:plc:viewer",
      {
        id: "clip-1",
        episodeId: "episode",
        startSeconds: 1.25,
        endSeconds: 31.75,
        title: "Clip",
        status: "complete",
        audioUrl: "https://gateway/auth/audio",
        videoUrl: "https://gateway/auth/video",
        publicAudioUrl: "https://gateway/public/audio",
        publicVideoUrl: "https://gateway/public/video",
        createdAt: "2026-10-05T01:00:00Z",
      },
      {
        id: "episode",
        showId: "show",
        title: "Episode",
        audioUrl: "https://publisher/audio.mp3",
        publishedAt: "2026-10-04T01:00:00Z",
        transcripts: [],
      },
    );
    const record = (writes[0] as { record: Record<string, unknown> }).record;
    expect(record.startMillis).toBe(1250);
    expect(record.endMillis).toBe(31750);
    expect(record.startSeconds).toBeUndefined();
    expect(record.audioUrl).toBe("https://gateway/public/audio");
    expect(record.videoUrl).toBe("https://gateway/public/video");
    expect(fetch).toHaveBeenCalledWith(
      oauth,
      "/v1/podcasts/clips/publish",
      expect.objectContaining({ method: "POST" }),
    );
  });
});
