import sharp from "sharp";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { TranscriptCue } from "./types";

const escapeXml=(text:string)=>text.replace(/[&<>"']/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&apos;"}[char]!));
function lines(text:string,max=38):string[] {
  const result:string[]=[];let line="";
  for(const word of text.replace(/<[^>]*>/g,"").split(/\s+/)) {
    if(line.length+word.length+1>max && line){result.push(line);line="";}
    line+=`${line?" ":""}${word}`;
  }
  if(line)result.push(line);
  return result;
}
function textSvg(text:string,y:number,size:number,maxLines:number):string {
  return lines(text,size>30?38:48).slice(0,maxLines).map((line,index)=>`<text x="540" y="${y+index*(size+14)}" fill="white" text-anchor="middle" font-family="DejaVu Sans,sans-serif" font-size="${size}">${escapeXml(line)}</text>`).join("");
}

// Rasterize text ourselves rather than relying on optional drawtext/libass filters.
// Every slide interval corresponds to original publisher cues shifted to clip time.
export async function createSlides(options:{directory:string;artwork?:string;title:string;attribution:string;cues:TranscriptCue[];start:number;end:number}):Promise<string> {
  // Bound image work before allocating frames. Invalid publisher timestamps cannot
  // become concat durations; dense transcripts fail visibly and can be exported without captions.
  const cues=options.cues.filter(cue=>Number.isFinite(cue.startSeconds)&&cue.startSeconds>=0&&(cue.endSeconds===undefined||Number.isFinite(cue.endSeconds))).sort((a,b)=>a.startSeconds-b.startSeconds);
  options={...options,cues};
  const artwork=options.artwork?await sharp(options.artwork,{limitInputPixels:40_000_000}).resize(900,900,{fit:"contain",background:"#171923"}).png().toBuffer():undefined;
  const boundaries=new Set([options.start,options.end]);
  for(let index=0;index<options.cues.length;index++) {
    const cue=options.cues[index]!;const end=cue.endSeconds??options.cues[index+1]?.startSeconds??options.end;
    if(cue.startSeconds>options.start && cue.startSeconds<options.end)boundaries.add(cue.startSeconds);
    if(end>options.start&&end<options.end)boundaries.add(end);
  }
  const times=[...boundaries].sort((a,b)=>a-b);
  if(times.length>2402)throw new Error("Transcript has too many caption transitions; export without captions");
  const entries=["ffconcat version 1.0"];let lastFile="";
  for(let index=0;index<times.length-1;index++) {
    const time=times[index]!;
    const cue=options.cues.find((cue,cueIndex)=>cue.startSeconds<=time&&(cue.endSeconds??options.cues[cueIndex+1]?.startSeconds??options.end)>time);
    const svg=Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920"><rect width="1080" height="1920" fill="#171923"/>${textSvg(options.title,1140,40,3)}${textSvg(options.attribution,1480,28,2)}${cue?textSvg(cue.text,1630,32,5):""}</svg>`);
    const image=sharp(svg);
    if(artwork)image.composite([{input:artwork,left:90,top:180}]);
    lastFile=join(options.directory,`slide-${index}.png`);
    await image.png().toFile(lastFile);
    entries.push(`file '${lastFile}'`,`duration ${times[index+1]!-time}`);
  }
  entries.push(`file '${lastFile}'`);
  const path=join(options.directory,"slides.txt");await writeFile(path,entries.join("\n"));return path;
}
