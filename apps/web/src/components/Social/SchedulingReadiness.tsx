"use client";

export function SchedulingReadiness({ connected, pending, failed, connectUrl, retry }: { connected?: boolean; pending: boolean; failed: boolean; connectUrl: string; retry: () => void }) {
  if (pending) return <p role="status" className="text-xs text-muted-foreground">Checking Scheduling…</p>;
  if (failed) return <p role="alert" className="text-sm text-destructive">Scheduling Could Not Be Loaded. <button type="button" className="underline" onClick={retry}>Retry</button></p>;
  if (!connected) return <p className="text-sm text-muted-foreground">Connect This Account to Skej to Publish While This App Is Closed. <a href={connectUrl} target="_blank" rel="noopener noreferrer" className="text-primary underline">Connect Scheduling</a><button type="button" onClick={retry} className="ml-2 text-primary underline">Check Connection</button></p>;
  return <p className="text-xs text-muted-foreground">Skej Will Publish This Post Even When This App Is Closed.</p>;
}
