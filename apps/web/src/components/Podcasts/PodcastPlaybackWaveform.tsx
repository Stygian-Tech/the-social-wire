"use client";

import { useEffect, useState } from "react";
import type { PlayerContext } from "./PodcastPlayerProvider";

const restingLevels = [0.3, 0.6, 0.9, 0.5, 0.75];
const visualSensitivity = 0.6;
type CapturableAudio = HTMLAudioElement & { captureStream?: () => MediaStream; mozCaptureStream?: () => MediaStream };

export function PodcastPlaybackWaveform({ player }: { player: PlayerContext }) {
  const { playing, getAudioElement } = player;
  const episodeId = player.episode?.id;
  const [levels, setLevels] = useState(restingLevels);
  const [analyzing, setAnalyzing] = useState(false);
  useEffect(() => {
    if (!playing) return;
    const audio = getAudioElement?.() as CapturableAudio | null | undefined;
    const capture = audio?.captureStream ?? audio?.mozCaptureStream;
    // Capture a separate stream: routing the original media element through Web Audio
    // can mute cross-origin podcasts. Unsupported browsers retain a playback indicator.
    if (!audio || !capture || typeof AudioContext === "undefined") return;
    let context: AudioContext | undefined;
    let source: MediaStreamAudioSourceNode | undefined;
    let stream: MediaStream | undefined;
    let timer: ReturnType<typeof setInterval> | undefined;
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      audio.removeEventListener("playing", startAnalysis);
      stream?.removeEventListener("addtrack", startAnalysis);
      if (timer) clearInterval(timer);
      source?.disconnect();
      stream?.getTracks().forEach(track => track.stop());
      if (context) void context.close().catch(() => {});
    };
    function startAnalysis() {
      if (released) return;
      if (context) {
        // A capture graph can be created before the browser grants playback.
        // Retry resume when the media starts after a user gesture.
        if (context.state === "suspended") void context.resume().catch(() => {});
        return;
      }
      if (!stream || stream.getAudioTracks().length === 0) return;
      try {
        context = new AudioContext();
        source = context.createMediaStreamSource(stream);
        const analyser = context.createAnalyser();
        analyser.fftSize = 4096;
        source.connect(analyser);
        void context.resume().catch(() => {});
        const frequencies = new Uint8Array(new ArrayBuffer(analyser.frequencyBinCount));
        const sampleRate = context.sampleRate;
        const highestFrequency = Math.min(20_000, sampleRate / 2);
        // Equal distances on a logarithmic scale represent equal musical ranges.
        // Restrict each band to captured FFT bins, including lower-rate media.
        const bands = restingLevels.map((_, band) => {
          const lower = 20 * (highestFrequency / 20) ** (band / restingLevels.length);
          const upper = 20 * (highestFrequency / 20) ** ((band + 1) / restingLevels.length);
          return {
            start: Math.min(frequencies.length, Math.max(1, Math.ceil(lower * analyser.fftSize / sampleRate))),
            end: Math.min(frequencies.length, Math.ceil(upper * analyser.fftSize / sampleRate)),
          };
        });
        timer = setInterval(() => {
          analyser.getByteFrequencyData(frequencies);
          const next = bands.map(({ start, end }) => {
            let peak = 0;
            for (let i = start; i < end; i++) peak = Math.max(peak, frequencies[i] ?? 0);
            return Math.max(0.08, peak / 255);
          });
          setAnalyzing(context?.state === "running");
          setLevels(next);
        }, 100);
      } catch {
        release();
      }
    }
    try {
      stream = capture.call(audio);
      // Chromium may expose an empty stream before the media is ready. Keep the
      // capture alive and start analysis once its audio track arrives.
      stream.addEventListener("addtrack", startAnalysis);
      audio.addEventListener("playing", startAnalysis);
      startAnalysis();
    } catch {
      release();
    }
    return () => { release(); setAnalyzing(false); setLevels(restingLevels); };
  }, [playing, getAudioElement, episodeId]);
  if (!playing) return null;
  return <span aria-hidden="true" className="flex h-4 w-5 shrink-0 items-center justify-center gap-0.5 text-primary">
    {levels.map((level, index) => <span key={index}
      className={`w-0.5 rounded-full bg-current transition-[height] duration-100 ${analyzing ? "" : "podcast-waveform-indicator motion-reduce:animate-none"}`}
      style={{ height: `${Math.max(1, Math.round(level * 16 * visualSensitivity))}px`, animationDelay: `${-index * 170}ms` }} />)}
  </span>;
}
