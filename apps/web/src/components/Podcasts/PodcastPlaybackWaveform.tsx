"use client";

import { useEffect, useState } from "react";
import type { PlayerContext } from "./PodcastPlayerProvider";

const restingLevels = [0.3, 0.6, 0.9, 0.5, 0.75];
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
    const release = () => {
      if (timer) clearInterval(timer);
      source?.disconnect();
      stream?.getTracks().forEach(track => track.stop());
      if (context) void context.close().catch(() => {});
    };
    try {
      stream = capture.call(audio);
      if (stream.getAudioTracks().length === 0) {
        release();
        return;
      }
      context = new AudioContext();
      source = context.createMediaStreamSource(stream);
      const analyser = context.createAnalyser();
      analyser.fftSize = 256;
      source.connect(analyser);
      void context.resume().catch(() => {});
      const frequencies = new Uint8Array(new ArrayBuffer(analyser.frequencyBinCount));
      timer = setInterval(() => {
        analyser.getByteFrequencyData(frequencies);
        const next = restingLevels.map((_, band) => {
          const start = band * 8 + 1;
          let peak = 0;
          for (let i = start; i < start + 8; i++) peak = Math.max(peak, frequencies[i] ?? 0);
          return Math.max(0.08, peak / 255);
        });
        setAnalyzing(context?.state === "running");
        setLevels(next);
      }, 100);
    } catch {
      release();
      return;
    }
    return () => { release(); setAnalyzing(false); setLevels(restingLevels); };
  }, [playing, getAudioElement, episodeId]);
  if (!playing) return null;
  return <span aria-hidden="true" className="flex h-4 w-5 shrink-0 items-center justify-center gap-0.5 text-primary">
    {levels.map((level, index) => <span key={index}
      className={`w-0.5 rounded-full bg-current transition-[height] duration-100 ${analyzing ? "" : "animate-pulse motion-reduce:animate-none"}`}
      style={{ height: `${Math.round(level * 16)}px`, animationDelay: `${index * 130}ms` }} />)}
  </span>;
}
