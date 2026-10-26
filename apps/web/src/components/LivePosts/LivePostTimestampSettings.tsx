"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
import { liveTimestampSettings, validateLiveTimestampSettings, type LiveTimestampSettings } from "@/lib/livePosts/livePostTimestamp";
import { LivePostTimestampFields } from "./LivePostTimestampFields";

export function LivePostTimestampSettings({ event, pending, now, onSave }: { event: LiveEvent; pending: boolean; now: string; onSave: (event: LiveEvent, settings: LiveTimestampSettings) => Promise<unknown> }) {
  const [settings, setSettings] = useState(() => liveTimestampSettings(event));
  const [error, setError] = useState<string>();
  const [saved, setSaved] = useState(false);
  async function save() {
    setError(undefined); setSaved(false);
    try { validateLiveTimestampSettings(settings); await onSave(event, settings); setSaved(true); }
    catch (failure) { setError(failure instanceof Error ? failure.message : "Timestamp settings could not be saved."); }
  }
  return <details className="mb-4 rounded-xl border p-3"><summary className="cursor-pointer text-sm font-medium">Timestamp Settings</summary>
    <form className="mt-3 space-y-3" onSubmit={submit => { submit.preventDefault(); void save(); }}>
      <LivePostTimestampFields value={settings} onChange={value => { setSettings(value); setSaved(false); }} disabled={pending} now={now} />
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      {saved ? <p role="status" className="text-sm">Timestamp Settings Saved</p> : null}
      <Button type="submit" variant="outline" disabled={pending}>Save Timestamp Settings</Button>
    </form>
  </details>;
}
