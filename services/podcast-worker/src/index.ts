import { SQL, S3Client } from "bun";
import { timingSafeEqual } from "node:crypto";
import { PodcastBridge } from "./bridge";
import { PodcastWorker } from "./worker";

function required(name:string):string {const value=process.env[name];if(!value)throw new Error(`${name} is required`);return value;}
const database=new SQL(required("DATABASE_URL"));
const storage=new S3Client({endpoint:required("PODCAST_S3_ENDPOINT"),bucket:required("PODCAST_S3_BUCKET"),accessKeyId:required("PODCAST_S3_ACCESS_KEY_ID"),secretAccessKey:required("PODCAST_S3_SECRET_ACCESS_KEY"),region:process.env.PODCAST_S3_REGION??"auto"});
const secret=required("PODCAST_MEDIA_INTERNAL_SECRET");
const bridge=process.env.PODCAST_BRIDGE_DID ? new PodcastBridge({did:required("PODCAST_BRIDGE_DID"),pds:required("PODCAST_BRIDGE_PDS_URL").replace(/\/$/,""),identifier:required("PODCAST_BRIDGE_IDENTIFIER"),password:required("PODCAST_BRIDGE_APP_PASSWORD")},database):undefined;
const worker=new PodcastWorker(database,storage,bridge);
let stopping=false;let ready=false;let lastTick=Date.now();
const internal=(request:Request)=>{const given=Buffer.from(request.headers.get("X-Podcast-Media-Secret")??"");const expected=Buffer.from(secret);return given.length===expected.length&&timingSafeEqual(given,expected);};

Bun.serve({port:Number(process.env.PORT??8080),async fetch(request) {
  const url=new URL(request.url);
  if(url.pathname==="/healthz")return Response.json({status:!stopping&&Date.now()-lastTick<1_200_000?"ok":"unhealthy"},{status:!stopping&&Date.now()-lastTick<1_200_000?200:503});
  if(url.pathname==="/startupz")return Response.json({ready},{status:ready?200:503});
  if(process.env.PODCASTS_ENABLED!=="true")return new Response("Not Found",{status:404});
  const match=url.pathname.match(/^\/(internal\/)?assets\/([0-9a-f-]{36})\/(audio\.m4a|audiogram\.mp4)$/i);
  if(!match||!['GET','HEAD'].includes(request.method))return new Response("Not Found",{status:404});
  const [,privatePath,clipId,filename]=match;
  if(privatePath&&!internal(request))return new Response("Unauthorized",{status:401});
  const rows=await database`SELECT published_uri,clip_json FROM podcast_clips WHERE id=${clipId!}::uuid`;
  if(!rows.length||(!privatePath&&!rows[0].published_uri)||rows[0].clip_json.status!=="complete")return new Response("Not Found",{status:404});
  const object=storage.file(`clips/${clipId}/${filename}`);
  const size=object.size;
  // S3File.size needs stat metadata on Bun: use stat for correct Range bounds.
  const metadata=await object.stat();const length=metadata.size??size;
  let start=0;let end=length-1;let partial=false;
  const range=request.headers.get("range");
  if(range) {
    const parsed=range.match(/^bytes=(\d*)-(\d*)$/);
    if(!parsed||(!parsed[1]&&!parsed[2]))return new Response(null,{status:416,headers:{"Content-Range":`bytes */${length}`}});
    if(!parsed[1])start=Math.max(0,length-Number(parsed[2]));
    else {start=Number(parsed[1]);if(parsed[2])end=Math.min(end,Number(parsed[2]));}
    if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=length)return new Response(null,{status:416,headers:{"Content-Range":`bytes */${length}`}});
    partial=true;
  }
  return new Response(request.method==="HEAD"?null:object.slice(start,end+1).stream(),{status:partial?206:200,headers:{"Content-Type":filename==="audio.m4a"?"audio/mp4":"video/mp4","Content-Length":String(end-start+1),"Accept-Ranges":"bytes",...(partial?{"Content-Range":`bytes ${start}-${end}/${length}`}:{ }),"Cache-Control":"private, no-store","Access-Control-Allow-Origin":"*"}});
}});

await database`SELECT id FROM podcast_jobs LIMIT 0`; // Migrator deploy dependency + actual readiness check.
ready=true;
process.on("SIGTERM",()=>{stopping=true;});process.on("SIGINT",()=>{stopping=true;});
while(!stopping) {
  if(process.env.PODCASTS_ENABLED==="true") {
    try {await worker.tick();lastTick=Date.now();}catch {console.error(JSON.stringify({event:"podcast_worker_tick_failed"}));}
  } else lastTick=Date.now();
  await Bun.sleep(2000);
}
await database.close();
