import { describe, expect, it } from "bun:test";
import sharp from "sharp";
import { createArtworkFrame } from "../src/slides";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { analyzeSilence, clipCaptions, probeDuration, renderClip, runMedia, silenceIntervals, validateClip } from "../src/media";

describe("source-time media processing",()=>{
  it("retains speech padding and handles trailing silence",()=>{
    expect(silenceIntervals("silence_start: 2\nsilence_end: 4\nsilence_start: 8",10)).toEqual([{start:2.1,end:3.9},{start:8.1,end:10}]);
  });
  it("removes a short quiet room-tone pause while retaining audible speech edges",async()=>{
    const directory=await mkdtemp(join(tmpdir(),"podcast-pause-test-"));
    try {
      const source=join(directory,"quiet-pause.wav");
      // A .45s -40dB room-tone pause was ineligible under the old -45dB/.6s detector.
      await runMedia("ffmpeg",["-loglevel","error","-f","lavfi","-i","sine=frequency=440:duration=1","-f","lavfi","-i","sine=frequency=100:duration=0.45","-f","lavfi","-i","sine=frequency=440:duration=1","-filter_complex","[1:a]volume=0.08[quiet];[0:a][quiet][2:a]concat=n=3:v=0:a=1[out]","-map","[out]",source]);
      const legacy=await runMedia("ffmpeg",["-hide_banner","-nostdin","-i",source,"-af","silencedetect=noise=-45dB:d=0.6","-f","null","-"]);
      expect(legacy).not.toContain("silence_start:");
      const intervals=await analyzeSilence(source,await probeDuration(source));
      expect(intervals).toHaveLength(1);
      expect(intervals[0]!.start).toBeGreaterThanOrEqual(1.08);
      expect(intervals[0]!.end).toBeLessThanOrEqual(1.37);
      expect(intervals[0]!.end-intervals[0]!.start).toBeGreaterThan(.2);
    } finally {await rm(directory,{recursive:true,force:true});}
  });
  it("clips captions to source bounds and shifts the exported timeline",()=>{
    const text=clipCaptions([{startSeconds:3,endSeconds:7,text:"<b>Hello</b>"},{startSeconds:8,endSeconds:12,text:"Later"}],5,10);
    expect(text).toContain("00:00:00,000 --> 00:00:02,000\nHello");
    expect(text).toContain("00:00:03,000 --> 00:00:05,000\nLater");
  });
  it("rejects invalid/out-of-bounds rendering requests",()=>{
    for(const [start,end] of [[-1,1],[2,1],[0,11],[NaN,1],[0,Infinity]])expect(()=>validateClip(start!,end!,10)).toThrow();
    expect(()=>validateClip(0,601,1000)).toThrow();
    expect(()=>validateClip(0,600,1000)).not.toThrow();
    expect(()=>validateClip(0,1,NaN)).toThrow();
  });
  it("fits all artwork edges into one frame without cropping",async()=>{
    const directory=await mkdtemp(join(tmpdir(),"podcast-artwork-test-"));
    try {
      const artwork=join(directory,"artwork.png");
      await sharp(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="300"><rect width="600" height="300" fill="red"/><rect x="590" width="10" height="300" fill="blue"/></svg>')).png().toFile(artwork);
      const frame=await createArtworkFrame({directory,artwork,title:"Episode",attribution:"Publisher"});
      const pixel=async(x:number,y:number)=>Array.from(await sharp(frame).extract({left:x,top:y,width:1,height:1}).removeAlpha().raw().toBuffer());
      expect(await pixel(90,500)).toEqual([255,0,0]);
      expect(await pixel(989,500)).toEqual([0,0,255]);
      expect(await pixel(540,200)).toEqual([23,25,35]);
      expect(await pixel(540,1070)).toEqual([23,25,35]);
    } finally {await rm(directory,{recursive:true,force:true});}
  });
  it("loops static artwork for the complete selected audio interval despite legacy caption cues",async()=>{
    const directory=await mkdtemp(join(tmpdir(),"podcast-static-video-test-"));
    try {
      const source=join(directory,"source.wav");const artwork=join(directory,"artwork.png");
      await runMedia("ffmpeg",["-loglevel","error","-f","lavfi","-i","sine=frequency=440:duration=10",source]);
      await sharp({create:{width:600,height:300,channels:3,background:"#eb4433"}}).png().toFile(artwork);
      const rendered=await renderClip({source,directory,start:.5,end:9.5,duration:10,artwork,title:"Episode",attribution:"Publisher",cues:[{startSeconds:.5,endSeconds:1,text:"First caption"},{startSeconds:1,endSeconds:2.5,text:"Different caption"}]});
      const metadata=JSON.parse(await runMedia("ffprobe",["-v","error","-show_entries","stream=codec_name,duration,nb_frames,width,height","-of","json",rendered.video]));
      const video=metadata.streams.find((stream:{codec_name:string})=>stream.codec_name==="h264");
      const audio=metadata.streams.find((stream:{codec_name:string})=>stream.codec_name==="aac");
      expect(video).toMatchObject({width:1080,height:1920,nb_frames:"270"});
      expect(Number(video.duration)).toBeCloseTo(9,2);expect(Number(audio.duration)).toBeCloseTo(9,1);
      expect(await probeDuration(rendered.audio)).toBeCloseTo(9,1);
      const frames=await runMedia("ffmpeg",["-v","error","-i",rendered.video,"-map","0:v:0","-f","framemd5","-"]);
      const hashes=frames.split("\n").filter(line=>line&&!line.startsWith("#")).map(line=>line.split(",").at(-1)?.trim());
      expect(hashes).toHaveLength(270);expect(new Set(hashes).size).toBe(1);
      const videoAudio=await runMedia("ffmpeg",["-v","error","-i",rendered.video,"-map","0:a:0","-f","md5","-"]);
      const selectedAudio=await runMedia("ffmpeg",["-v","error","-i",rendered.audio,"-map","0:a:0","-f","md5","-"]);
      expect(videoAudio).toBe(selectedAudio);
      const decoded=join(directory,"decoded.png");
      await runMedia("ffmpeg",["-v","error","-i",rendered.video,"-frames:v","1",decoded]);
      const center=Array.from(await sharp(decoded).extract({left:540,top:630,width:1,height:1}).removeAlpha().raw().toBuffer());
      expect(center[0]).toBeGreaterThan(220);expect(center[1]).toBeLessThan(80);expect(center[2]).toBeLessThan(70);
    } finally {await rm(directory,{recursive:true,force:true});}
  },60_000);
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
