import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { downloadPublic } from "./publicFetch";
import type { SilenceInterval, TranscriptCue } from "./types";
import { createSlides } from "./slides";

const INPUT_FORMATS = "mp3,mov,ogg,wav,flac,aac";
export async function runMedia(command: string, args: string[], timeoutMs = 900_000): Promise<string> {
  const process = Bun.spawn([command, ...args], {stdout: "pipe", stderr: "pipe"});
  const timer = setTimeout(() => process.kill(), timeoutMs);
  try {
    const [stdout, stderr, code] = await Promise.all([new Response(process.stdout).text(), new Response(process.stderr).text(), process.exited]);
    if (code !== 0) throw new Error(`${command} failed (${code}): ${stderr.slice(-1500)}`);
    return stdout || stderr;
  } finally { clearTimeout(timer); }
}

export async function withMedia<T>(url: string, work: (path: string, directory: string, validator: string) => Promise<T>): Promise<T> {
  const directory = await mkdtemp(join(tmpdir(), "socialwire-podcast-"));
  try {
    const path = join(directory, "source.audio");
    const validator = await downloadPublic(url, path);
    return await work(path, directory, validator);
  } finally { await rm(directory, {recursive: true, force: true}); }
}

export async function probeDuration(path: string): Promise<number> {
  const text = await runMedia("ffprobe", ["-v", "error", "-protocol_whitelist", "file,pipe", "-format_whitelist", INPUT_FORMATS, "-show_entries", "format=duration", "-of", "json", path]);
  const duration = Number(JSON.parse(text).format?.duration);
  if (!Number.isFinite(duration) || duration <= 0 || duration > 21600) throw new Error("Audio duration is missing or exceeds six-hour processing limit");
  return duration;
}

export function silenceIntervals(log: string, duration: number): SilenceInterval[] {
  const intervals: SilenceInterval[] = [];
  let start: number | undefined;
  for (const match of log.matchAll(/silence_(start|end):\s*([\d.]+)/g)) {
    const value = Number(match[2]);
    if (!Number.isFinite(value)) continue;
    if (match[1] === "start") start = value;
    else if (start !== undefined) {
      const interval = {start: Math.max(0, start + 0.15), end: Math.min(duration, value - 0.15)};
      if (interval.end > interval.start) intervals.push(interval);
      start = undefined;
    }
  }
  if (start !== undefined && duration - start > 0.6) intervals.push({start: start + 0.15, end: duration});
  return intervals;
}

export async function analyzeSilence(path: string, duration: number): Promise<SilenceInterval[]> {
  const log = await runMedia("ffmpeg", ["-hide_banner", "-nostdin", "-protocol_whitelist", "file,pipe", "-format_whitelist", INPUT_FORMATS, "-i", path, "-vn", "-af", "silencedetect=noise=-45dB:d=0.6", "-f", "null", "-"]);
  return silenceIntervals(log, duration);
}

function srtTime(seconds: number): string {
  const ms = Math.round(Math.max(0, seconds) * 1000);
  return `${String(Math.floor(ms/3600000)).padStart(2,"0")}:${String(Math.floor(ms/60000)%60).padStart(2,"0")}:${String(Math.floor(ms/1000)%60).padStart(2,"0")},${String(ms%1000).padStart(3,"0")}`;
}

export function clipCaptions(cues: TranscriptCue[], start: number, end: number): string {
  return cues.flatMap((cue, index) => {
    const cueEnd = cue.endSeconds ?? cues[index+1]?.startSeconds ?? end;
    const from = Math.max(start, cue.startSeconds); const to = Math.min(end, cueEnd);
    if (to <= from) return [];
    return [{from: from-start, to: to-start, text: cue.text.replace(/<[^>]*>/g, "").replace(/\r/g, "").replace(/\n{2,}/g,"\n")}];
  }).map((cue,index)=>`${index+1}\n${srtTime(cue.from)} --> ${srtTime(cue.to)}\n${cue.text}\n`).join("\n");
}

export function validateClip(start: number, end: number, duration: number): void {
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start || end > duration || end-start > 600) throw new Error("Clip must be within the episode and no longer than ten minutes");
}

export async function renderClip(options: {source: string; directory: string; start: number; end: number; duration: number; artwork?: string; title: string; attribution: string; cues?: TranscriptCue[]}): Promise<{audio: string; video: string}> {
  validateClip(options.start, options.end, options.duration);
  const audio = join(options.directory,"audio.m4a"); const video = join(options.directory,"audiogram.mp4");
  await runMedia("ffmpeg", ["-hide_banner","-loglevel","error","-nostdin","-y","-protocol_whitelist","file,pipe","-format_whitelist",INPUT_FORMATS,"-i", options.source, "-ss",String(options.start),"-t",String(options.end-options.start),"-vn","-c:a","aac","-b:a","192k","-movflags","+faststart",audio]);
  const slides=await createSlides({directory:options.directory,artwork:options.artwork,title:options.title,attribution:options.attribution,cues:options.cues??[],start:options.start,end:options.end});
  await runMedia("ffmpeg",["-hide_banner","-loglevel","error","-nostdin","-y","-f","concat","-safe","0","-i",slides,"-i",audio,"-filter_complex","[1:a]asplit[voice][wave];[wave]showwaves=s=900x220:mode=line:colors=white:rate=30[visual];[0:v][visual]overlay=90:1300[out]","-map","[out]","-map","[voice]","-c:v","libx264","-preset","veryfast","-pix_fmt","yuv420p","-r","30","-c:a","aac","-t",String(options.end-options.start),"-movflags","+faststart",video]);
  return {audio,video};
}
