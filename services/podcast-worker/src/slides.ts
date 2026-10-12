import sharp from "sharp";
import { join } from "node:path";

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

// Rasterize once: publisher captions remain metadata and never animate the video.
// Decode only the first artwork page, including animated GIF/WebP inputs.
export async function createArtworkFrame(options:{directory:string;artwork?:string;title:string;attribution:string}):Promise<string> {
  const artwork=options.artwork?await sharp(options.artwork,{limitInputPixels:40_000_000,pages:1}).rotate().resize(900,900,{fit:"contain",background:"#171923"}).png().toBuffer():undefined;
  const svg=Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1920"><rect width="1080" height="1920" fill="#171923"/>${textSvg(options.title,1140,40,3)}${textSvg(options.attribution,1480,28,2)}</svg>`);
  const image=sharp(svg);
  if(artwork)image.composite([{input:artwork,left:90,top:180}]);
  const path=join(options.directory,"artwork-frame.png");
  await image.png().toFile(path);
  return path;
}
