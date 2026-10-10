import { lookup } from "node:dns/promises";
import { request } from "node:https";
import { isIP } from "node:net";
import { createWriteStream } from "node:fs";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

export function isPublicAddress(address: string): boolean {
  const lower = address.toLowerCase();
  if (isIP(lower) === 4) {
    const [a,b] = lower.split(".").map(Number);
    return a !== 0 && a !== 10 && a !== 127 && a! < 224 && !(a === 169 && b === 254)
      && !(a === 172 && b! >= 16 && b! <= 31) && !(a === 192 && b === 168)
      && !(a === 100 && b! >= 64 && b! <= 127) && !(a === 198 && (b === 18 || b === 19));
  }
  // Reject special-use/mapped IPv6; globally routable unicast is 2000::/3.
  return isIP(lower) === 6 && /^[23][0-9a-f]{0,3}:/.test(lower) && !lower.startsWith("2001:db8:");
}

export function publicUrl(raw: string): URL {
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443")) throw new Error("Only public HTTPS media is supported");
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (host === "localhost" || !host.includes(".") && !isIP(host) || host.endsWith(".local") || host.endsWith(".internal") || (isIP(host) && !isPublicAddress(host))) throw new Error("Private media address rejected");
  return url;
}

export function publicFeedUrl(raw:string):URL {
  const url=publicUrl(raw);
  // RSS mirrors publish their source URL. Accept only conventional public feed
  // selectors; credentials in arbitrary query parameters must never be mirrored.
  for(const [name,value] of url.searchParams) {
    if(!["feed","format"].includes(name.toLowerCase())||!["rss","rss2","atom","rdf","xml"].includes(value.toLowerCase()))throw new Error("Private or tokenized RSS feeds are not supported");
  }
  return url;
}

// Pin the validated DNS result on each hop. Never let a second DNS lookup redirect
// a publisher-controlled host to Railway/private metadata services.
export async function fetchPublic(raw: string, maxBytes = 8 * 1024 * 1024, redirects = 5, validate?: (url:string)=>unknown): Promise<Response> {
  validate?.(raw);
  const url = publicUrl(raw);
  const host = url.hostname.replace(/^\[|\]$/g, "");
  const addresses = isIP(host) ? [{address: host, family: isIP(host)}] : await lookup(host, {all: true});
  if (!addresses.length || addresses.some(a => !isPublicAddress(a.address))) throw new Error("Private DNS address rejected");
  const chosen = addresses[0]!;
  const incoming = await new Promise<import("node:http").IncomingMessage>((resolve, reject) => {
    const req = request(url, {
      headers: {"User-Agent": "TheSocialWire-PodcastBridge/1.0"},
      lookup: (_hostname, options, callback) => {
        if (typeof options === "object" && options.all) callback(null, [chosen]);
        else callback(null, chosen.address, chosen.family);
      },
    }, resolve);
    req.setTimeout(30_000, () => req.destroy(new Error("Media fetch timed out")));
    req.on("error", reject); req.end();
  });
  const status = incoming.statusCode ?? 502;
  if ([301,302,303,307,308].includes(status)) {
    incoming.destroy();
    if (redirects <= 0 || !incoming.headers.location) throw new Error("Media redirect limit reached");
    return fetchPublic(new URL(incoming.headers.location, url).href, maxBytes, redirects - 1,validate);
  }
  if (status < 200 || status >= 300) { incoming.destroy(); throw new Error(`Publisher returned ${status}`); }
  if (Number(incoming.headers["content-length"] ?? 0) > maxBytes) { incoming.destroy(); throw new Error("Media exceeds processing limit"); }
  let bytes = 0;
  const bounded = new Transform({transform(chunk, _encoding, callback) {
    bytes += chunk.length;
    callback(bytes > maxBytes ? new Error("Media exceeds processing limit") : null, chunk);
  }});
  incoming.on("error", error => bounded.destroy(error));
  bounded.on("error",()=>incoming.destroy());
  incoming.pipe(bounded);
  const headers = new Headers();
  for (const name of ["content-type", "content-length", "etag", "last-modified"]) {
    const value = incoming.headers[name]; if (typeof value === "string") headers.set(name, value);
  }
  return new Response(Readable.toWeb(bounded) as unknown as ReadableStream<Uint8Array>, {status, headers});
}

export async function downloadPublic(url: string, path: string, maxBytes = 512 * 1024 * 1024): Promise<string> {
  const response = await fetchPublic(url, maxBytes);
  if (!response.body) throw new Error("Empty publisher response");
  await pipeline(Readable.fromWeb(response.body as unknown as import("node:stream/web").ReadableStream), createWriteStream(path, {flags:"wx"}));
  return [response.headers.get("etag")??"",response.headers.get("last-modified")??"",response.headers.get("content-length")??""].join("|");
}
