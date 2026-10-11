"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { SidebarTrigger } from "@/components/ui/sidebar";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { HOSTED_STREAMPLACE, streamplaceNodeOrigin } from "@/lib/livestream/streamplaceNode";
import { LivestreamNodeWorkspace } from "./LivestreamNodeWorkspace";
export function LivestreamAccountWorkspace() {
  const [node, setNode] = useState(HOSTED_STREAMPLACE), [custom, setCustom] = useState(""), [error, setError] = useState<string>();
  return <div className="flex min-w-0 flex-1 flex-col overflow-y-auto p-2">
    <header className={`${floatingGlassClasses} mb-3 flex items-center gap-3 p-3`}><SidebarTrigger /><h1 className="text-xl font-semibold">Livestream</h1></header>
    <section className="mx-auto w-full max-w-5xl space-y-3 px-2">
      <div className="flex flex-wrap items-end gap-2"><Button variant={node === HOSTED_STREAMPLACE ? "default" : "outline"} onClick={() => { setNode(HOSTED_STREAMPLACE); setError(undefined); }}>Hosted Streamplace</Button><label className="min-w-0 flex-1 text-sm">Custom Node<Input aria-label="Custom Streamplace Node" placeholder="https://stream.example.com" value={custom} onChange={event => setCustom(event.target.value)} /></label><Button variant="outline" onClick={() => { try { setNode(streamplaceNodeOrigin(custom)); setError(undefined); } catch { setError("Use A Public HTTPS Node Origin."); } }}>Connect Node</Button></div>
      {error ? <p role="alert">{error}</p> : null}<p className="text-sm text-muted-foreground">Connected Node: {node}. Your PDS OAuth Credentials Are Never Sent To This Node.</p>
      <LivestreamNodeWorkspace key={node} node={node} />
    </section>
  </div>;
}
