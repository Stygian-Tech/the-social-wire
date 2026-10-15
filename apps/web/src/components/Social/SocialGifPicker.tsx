"use client";

/* eslint-disable @next/next/no-img-element -- Provider-owned previews. */
import { useEffect, useState } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getComposerGifs } from "@/lib/klipyClient";
import type { GifAsset } from "@/lib/composerMedia";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";

export function SocialGifPicker({ session, onSelect, onClose }: { session: OAuthSession; onSelect: (asset: GifAsset) => void; onClose: () => void }) {
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  useEffect(() => { const timer = setTimeout(() => setQuery(search.trim()), 250); return () => clearTimeout(timer); }, [search]);
  const results = useInfiniteQuery({
    queryKey: ["composerGifs", session.did, query], initialPageParam: "",
    queryFn: ({ pageParam, signal }) => getComposerGifs(session, { q: query, cursor: pageParam }, signal),
    getNextPageParam: page => page.next || undefined, retry: false, staleTime: 0, gcTime: 0,
  });
  const assets = [...new Map(results.data?.pages.flatMap(page => page.results).map(asset => [asset.id, asset])).values()];
  return <Dialog open onOpenChange={open => { if (!open) onClose(); }}><DialogContent className="max-h-[85dvh] overflow-y-auto sm:max-w-xl" onKeyDown={event => event.stopPropagation()}>
    <DialogTitle>Choose A GIF</DialogTitle><DialogDescription>Search GIFs From KLIPY</DialogDescription>
    <label className="flex flex-col gap-1 text-sm">Search GIFs<input autoFocus maxLength={200} value={search} onChange={event => setSearch(event.target.value)} className="rounded-xl border bg-background p-3" placeholder="Search KLIPY…" /></label>
    <p className="text-xs text-muted-foreground">Powered by <a href="https://klipy.com" target="_blank" rel="noopener noreferrer" className="underline">KLIPY</a></p>
    {results.isPending || search.trim() !== query ? <p role="status">Loading GIFs…</p> : null}
    {results.isError ? <div role="alert"><p>{results.error.message}</p><Button type="button" variant="outline" onClick={() => void results.refetch()}>Retry</Button></div> : null}
    {!results.isPending && !results.isError && !assets.length ? <p role="status">No GIFs Found. Try Another Search.</p> : null}
    <div className="grid min-w-0 grid-cols-2 gap-3 sm:grid-cols-3">{assets.map(asset => <button type="button" key={asset.id} disabled={search.trim() !== query} aria-label={`Select GIF: ${asset.description || asset.title}`} onClick={() => onSelect(asset)} className="flex aspect-square min-w-0 items-center justify-center overflow-hidden rounded-xl border bg-muted p-2 focus-visible:outline-2 focus-visible:outline-ring disabled:opacity-50"><img src={asset.poster} alt={asset.description || asset.title} width={asset.width} height={asset.height} loading="lazy" referrerPolicy="no-referrer" className="h-full w-full object-contain" /></button>)}</div>
    {results.hasNextPage ? <Button type="button" variant="outline" disabled={results.isFetchingNextPage} onClick={() => void results.fetchNextPage()}>{results.isFetchingNextPage ? "Loading…" : "Load More"}</Button> : null}
  </DialogContent></Dialog>;
}
