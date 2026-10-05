import { describe, expect, it } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { analyzeSilence, clipCaptions, probeDuration, renderClip, runMedia, silenceIntervals, validateClip } from "../src/media";

describe("source-time media processing",()=>{
  it("retains speech padding and handles trailing silence",()=>{
    expect(silenceIntervals("silence_start: 2\nsilence_end: 4\nsilence_start: 8",10)).toEqual([{start:2.15,end:3.85},{start:8.15,end:10}]);
  });
  it("clips captions to source bounds and shifts the exported timeline",()=>{
    const text=clipCaptions([{startSeconds:3,endSeconds:7,text:"<b>Hello</b>"},{startSeconds:8,endSeconds:12,text:"Later"}],5,10);
    expect(text).toContain("00:00:00,000 --> 00:00:02,000\nHello");
    expect(text).toContain("00:00:03,000 --> 00:00:05,000\nLater");
  });
  it("rejects invalid/out-of-bounds rendering requests",()=>{
    for(const [start,end] of [[-1,1],[2,1],[0,11],[NaN,1]])expect(()=>validateClip(start!,end!,10)).toThrow();
  });
  it("analyzes actual audio and renders playable AAC/MP4 exports",async()=>{
    const directory=await mkdtemp(join(tmpdir(),"podcast-media-test-"));
    try {
      const source=join(directory,"source.wav");
      await runMedia("ffmpeg",["-loglevel","error","-f","lavfi","-i","sine=frequency=440:duration=1","-f","lavfi","-i","anullsrc=r=44100:cl=mono:d=1","-filter_complex","[0:a][1:a]concat=n=2:v=0:a=1[out]","-map","[out]",source]);
      const duration=await probeDuration(source);expect(duration).toBeCloseTo(2,1);
      const intervals=await analyzeSilence(source,duration);expect(intervals.length).toBe(1);expect(intervals[0]!.start).toBeGreaterThan(1);
      const rendered=await renderClip({source,directory,start:0,end:1,duration,title:"Test Episode",attribution:"Test Publisher",cues:[{startSeconds:0,endSeconds:1,text:"Test Caption"}]});
      expect(await probeDuration(rendered.audio)).toBeCloseTo(1,1);
      const metadata=JSON.parse(await runMedia("ffprobe",["-v","error","-show_entries","stream=codec_name,width,height","-of","json",rendered.video]));
      expect(metadata.streams).toContainEqual({codec_name:"h264",width:1080,height:1920});
    } finally {await rm(directory,{recursive:true,force:true});}
  },60_000);
});
