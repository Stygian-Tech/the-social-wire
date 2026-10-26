"use client";

import { ChevronDown } from "lucide-react";
import { Input } from "@/components/ui/input";
import { formatLiveTimestamp, LIVE_TIMESTAMP_FORMATS, type LiveTimestampSettings } from "@/lib/livePosts/livePostTimestamp";

const labels = { "time-24": "24-Hour Time", "time-12": "12-Hour Time", "date-time": "Local Date and Time", iso: "ISO Timestamp (UTC)" };

export function LivePostTimestampFields({ value, onChange, disabled, now }: { value: LiveTimestampSettings; onChange: (value: LiveTimestampSettings) => void; disabled: boolean; now: string }) {
  let preview: string;
  try { preview = formatLiveTimestamp(now, value); }
  catch { preview = "Enter a valid IANA time zone to preview."; }
  return <fieldset disabled={disabled} className="min-w-0 space-y-3">
    <legend className="mb-2 text-sm font-medium">Article Timestamps</legend>
    <label className="block space-y-1 text-sm"><span>Timestamp Format</span><div className="relative"><select aria-label="Timestamp Format" value={value.timestampFormat} onChange={event => onChange({ ...value, timestampFormat: event.target.value as LiveTimestampSettings["timestampFormat"] })} className="w-full appearance-none rounded-md border bg-background py-2 pl-3 pr-9">{LIVE_TIMESTAMP_FORMATS.map(format => <option key={format} value={format}>{labels[format]}</option>)}</select><ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2" /></div></label>
    <label className="block space-y-1 text-sm"><span>Time Zone</span><Input aria-label="Time Zone" value={value.timeZone} onChange={event => onChange({ ...value, timeZone: event.target.value })} placeholder="America/Chicago" required maxLength={128} /></label>
    <p className="break-words text-xs text-muted-foreground" aria-live="polite">Preview: <output aria-label="Timestamp Preview">{preview}</output></p>
    <p className="text-xs text-muted-foreground">Saved with this event for future article updates. Earlier published entries stay as they are.</p>
  </fieldset>;
}
