import { expect, test } from "bun:test";
import { protocolEpisode } from "../src/protocol";
import type { PodcastShow } from "../src/types";

test("publisher family adapters only accept audio belonging to the resolved show",()=>{
  const org:PodcastShow={id:"stable-show",title:"Show",sourceKind:"atproto",guid:"guid",sourceUri:"at://did:plc:publisher/org.atpodcasting.podcast/show"};
  expect(protocolEpisode("at://episode",{title:"Audio",podcast:{podcastGuid:"guid"},media:{url:"https://example.com/a.mp3",mimeType:"audio/mpeg"},feedItemGuid:"original"},org,"https://pds.example")?.guid).toBe("original");
  expect(protocolEpisode("at://episode",{title:"Audio",podcast:{podcastGuid:"other"},media:{url:"https://example.com/a.mp3",mimeType:"audio/mpeg"}},org,"https://pds.example")).toBeUndefined();
  const place={...org,sourceUri:"at://did:plc:publisher/place.pod.show/show"};
  const record={title:"Audio",showUri:place.sourceUri,audio:{mimeType:"audio/mp4",ref:{$link:"blob"}},transcript:{url:"https://example.com/a.vtt",mimeType:"text/vtt"}};
  const episode=protocolEpisode("at://episode",record,place,"https://pds.example");
  expect(episode?.audioUrl).toContain("com.atproto.sync.getBlob");expect(episode?.transcripts[0]?.type).toBe("text/vtt");
  expect(protocolEpisode("at://episode",{...record,audio:{mimeType:"video/mp4",ref:{$link:"blob"}}},place,"https://pds.example")).toBeUndefined();
  const vox={...org,sourceUri:"at://did:plc:publisher/live.voxport.podcast.series/show"};
  const voxRecord={title:"Audio",series:{uri:vox.sourceUri},audioUrl:"https://example.com/a.mp3",audioMimeType:"audio/mpeg"};
  expect(protocolEpisode("at://episode",voxRecord,vox,"https://pds.example")).toBeUndefined();
  expect(protocolEpisode("at://episode",{...voxRecord,publishedAt:"2026-10-05T00:00:00Z"},vox,"https://pds.example")?.showId).toBe("stable-show");
});
