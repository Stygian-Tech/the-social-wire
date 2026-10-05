"use client";
import { PodcastSelect } from "./PodcastSelect";
import { useState } from "react";
import type { PodcastTranscript } from "@/lib/podcasts/client";
import { formatPodcastTime } from "@/lib/podcasts/playback";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
export function PodcastTranscripts({
  transcripts,
}: {
  transcripts: PodcastTranscript[];
}) {
  const [language, setLanguage] = useState(0);
  const [search, setSearch] = useState("");
  const player = usePodcastPlayer();
  const transcript = transcripts[language] ?? transcripts[0];
  if (!transcript)
    return (
      <p className="text-sm text-muted-foreground">
        No Publisher Transcript Is Available.
      </p>
    );
  return (
    <section aria-label="Transcript" className="space-y-3">
      <div className="flex flex-wrap gap-3">
        <input
          aria-label="Search Transcript"
          placeholder="Search Transcript"
          className="min-h-11 rounded border bg-background px-3"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
        <PodcastSelect
          aria-label="Transcript Language"
          value={language}
          onChange={(event) => setLanguage(Number(event.target.value))}
          className="min-h-11 rounded border bg-background px-3"
        >
          {transcripts.map((item, index) => (
            <option key={`${item.url}:${index}`} value={index}>
              {item.language ?? "Original Language"} ({item.type})
            </option>
          ))}
        </PodcastSelect>
      </div>
      <div className="max-h-80 space-y-1 overflow-y-auto rounded border p-3">
        {transcript.cues?.length ? (
          transcript.cues.map((cue, index) => {
            if (
              search &&
              !cue.text.toLocaleLowerCase().includes(search.toLocaleLowerCase())
            )
              return null;
            const end =
              cue.endSeconds ??
              transcript.cues?.[index + 1]?.startSeconds ??
              Infinity;
            const active =
              player.position >= cue.startSeconds && player.position < end;
            return (
              <button
                key={`${cue.startSeconds}:${index}`}
                className={`block w-full rounded p-2 text-left text-sm ${active ? "bg-accent font-medium" : "hover:bg-accent/50"}`}
                aria-current={active ? "true" : undefined}
                onClick={() => player.seek(cue.startSeconds)}
              >
                <span className="mr-2 text-xs text-muted-foreground">
                  {formatPodcastTime(cue.startSeconds)}
                </span>
                {cue.text}
              </button>
            );
          })
        ) : transcript.text ? (
          <p className="whitespace-pre-wrap text-sm">
            {transcript.text
              .split(/\n/)
              .filter(
                (line) =>
                  !search ||
                  line.toLocaleLowerCase().includes(search.toLocaleLowerCase()),
              )
              .join("\n")}
          </p>
        ) : (
          <a
            href={transcript.url}
            target="_blank"
            rel="noreferrer"
            className="underline"
          >
            Open Publisher Transcript
          </a>
        )}
      </div>
    </section>
  );
}
