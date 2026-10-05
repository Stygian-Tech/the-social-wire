import { describe, expect, it } from "bun:test";
import { parsePodcast, seconds } from "../src/catalog";
import { podcastGuid, uuidV5 } from "../src/identity";
import { isPublicAddress, publicUrl, publicFeedUrl } from "../src/publicFetch";

describe("podcast source identity",()=>{
  it("uses the Podcasting 2.0 namespace and retains publisher GUID on moves",()=>{
    expect(podcastGuid("https://podnews.net/rss")).toBe("9b024349-ccf0-5f69-a609-6b82873eab3c");
    expect(podcastGuid("https://moved.example/feed","9b024349-ccf0-5f69-a609-6b82873eab3c")).toBe("9b024349-ccf0-5f69-a609-6b82873eab3c");
    expect(uuidV5("9b024349-ccf0-5f69-a609-6b82873eab3c","episode-1")).toBe(uuidV5("9b024349-ccf0-5f69-a609-6b82873eab3c","episode-1"));
  });
  it("preserves original episode GUID and transcript attributes",async()=>{
    const {show,episodes}=await parsePodcast(`<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title><podcast:guid>9b024349-ccf0-5f69-a609-6b82873eab3c</podcast:guid><item><title>Episode</title><guid>original-id</guid><enclosure url="https://example.com/audio.mp3" type="audio/mpeg"/><itunes:duration>01:02:03</itunes:duration><podcast:transcript url="https://example.com/transcript.vtt" type="text/vtt" language="en"/></item></channel></rss>`,"https://example.com/feed");
    expect(show.guid).toBe("9b024349-ccf0-5f69-a609-6b82873eab3c");
    expect(episodes[0]!.guid).toBe("original-id");expect(episodes[0]!.durationSeconds).toBe(3723);
    expect(episodes[0]!.transcripts).toEqual([{url:"https://example.com/transcript.vtt",type:"text/vtt",language:"en"}]);
  });
  it("retains supplied host photos, cloud chapters and inline PSC without guessed credits",async()=>{
    const {show,episodes}=await parsePodcast(`<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters"><channel><title>Show</title><podcast:person img="https://example.com/a.jpg">Alice</podcast:person><podcast:person role="co-host">Bob</podcast:person><podcast:person role="guest">Guest</podcast:person><item><title>Episode</title><guid>episode</guid><enclosure url="https://example.com/a.mp3" type="audio/mpeg"/><podcast:chapters url="https://example.com/chapters.json" type="application/json+chapters"/><psc:chapters><psc:chapter start="00:00:00" title="Intro" image="https://example.com/intro.jpg"/><psc:chapter start="01:02.500" title="Next"/></psc:chapters></item></channel></rss>`,"https://example.com/rss");
    expect(show.hosts?.map(host=>host.name)).toEqual(["Alice","Bob"]);
    expect(show.hosts?.[0]?.imageUrl).toBe("https://example.com/a.jpg");
    expect(episodes[0]?.chapterSourceUrl).toBe("https://example.com/chapters.json");
    expect(episodes[0]?.chapters?.map(chapter=>chapter.startSeconds)).toEqual([0,62.5]);
    expect(episodes[0]?.chapters?.[0]?.artworkUrl).toBe("https://example.com/intro.jpg");
  });
  it("keeps the complete available audio catalog",async()=>{
    const items=Array.from({length:205},(_,i)=>`<item><title>${i}</title><guid>${i}</guid><enclosure url="https://example.com/${i}.mp3" type="audio/mpeg"/></item>`).join("");
    const parsed=await parsePodcast(`<rss version="2.0"><channel><title>Show</title>${items}</channel></rss>`,"https://example.com/rss");
    expect(parsed.episodes).toHaveLength(205);
  });
  it("rejects video-only episodes and malformed durations",async()=>{
    expect(seconds("unknown")).toBeUndefined();
    const parsed=await parsePodcast(`<rss version="2.0"><channel><title>Show</title><item><title>Video</title><enclosure url="https://example.com/v.mp4" type="video/mp4"/></item></channel></rss>`,"https://example.com/rss");
    expect(parsed.episodes).toHaveLength(0);
  });
});

describe("public media boundaries",()=>{
  it("allows public feed selectors and rejects tokenized RSS sources",()=>{
    expect(publicFeedUrl("https://example.com/?feed=rss2").search).toBe("?feed=rss2");
    for(const url of ["https://example.com/rss?token=secret","https://example.com/rss?auth=secret","https://user:secret@example.com/rss","https://example.com/rss?format=credential","http://example.com/rss"])expect(()=>publicFeedUrl(url)).toThrow();
  });
  it("rejects private networks, metadata hosts and mapped IPv6",()=>{
    for(const address of ["127.0.0.1","10.1.2.3","172.31.1.1","169.254.169.254","100.64.0.1","192.168.1.1","::1","::ffff:127.0.0.1","fc00::1","fe80::1"])expect(isPublicAddress(address)).toBe(false);
    expect(isPublicAddress("8.8.8.8")).toBe(true);expect(isPublicAddress("2606:4700:4700::1111")).toBe(true);
  });
  it("rejects arbitrary protocols, embedded credentials and private hostnames",()=>{
    for(const url of ["file:///etc/passwd","http://example.com/a.mp3","https://user:pass@example.com/a.mp3","https://app.railway.internal/a.mp3","https://localhost/a.mp3","https://example.com:8000/a.mp3"])expect(()=>publicUrl(url)).toThrow();
  });
});
