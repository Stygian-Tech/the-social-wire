"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { HOSTED_STREAMPLACE, streamplaceNodeOrigin } from "@/lib/livestream/streamplaceNode";
import { LivestreamNodeWorkspace } from "./LivestreamNodeWorkspace";
export function LivestreamAccountWorkspace() {
  const [node, setNode] = useState(HOSTED_STREAMPLACE), [custom, setCustom] = useState(""), [error, setError] = useState<string>();
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
    <FeedHeader title="Livestream" />
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-4 pt-0 lg:overflow-hidden">
    <section className="flex w-full flex-col gap-3 lg:h-full lg:min-h-0">
      <div className="flex shrink-0 flex-wrap items-end gap-2"><Button variant={node === HOSTED_STREAMPLACE ? "default" : "outline"} onClick={() => { setNode(HOSTED_STREAMPLACE); setError(undefined); }}>Hosted Streamplace</Button><label className="min-w-0 flex-1 text-sm">Custom Node<Input aria-label="Custom Streamplace Node" placeholder="https://stream.example.com" value={custom} onChange={event => setCustom(event.target.value)} /></label><Button variant="outline" onClick={() => { try { setNode(streamplaceNodeOrigin(custom)); setError(undefined); } catch { setError("Use A Public HTTPS Node Origin."); } }}>Connect Node</Button></div>
      {error ? <p role="alert">{error}</p> : null}<p className="shrink-0 text-sm text-muted-foreground">Connected Node: {node}. Your PDS OAuth Credentials Are Never Sent To This Node.</p>
      <LivestreamNodeWorkspace key={node} node={node} />
    </section>
    </div>
  </div>;
}
