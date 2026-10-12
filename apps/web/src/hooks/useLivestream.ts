"use client";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { TID } from "@atproto/common-web";
import { useAuth } from "@/hooks/useAuth";
import { endLivestream, generateStreamKey, getStreamIngests, listLivestreams, saveLivestream, sendStreamChat, uploadStreamThumbnail } from "@/lib/livestream/streamplaceClient";
import { reduceStreamSnapshot } from "@/lib/livestream/streamplaceRealtime";
import { streamplaceNodeOrigin } from "@/lib/livestream/streamplaceNode";
import type { Livestream, LivestreamInput, StreamOperation, StreamSnapshot } from "@/lib/livestream/livestreamTypes";
export function useLivestream(node: string) {
  const { session, getOAuthSession } = useAuth(), did = session?.did;
  const identity = useRef({ did, node }), mounted = useRef(true), locked = useRef(false), attempts = useRef(new Map<string, StreamOperation>());
  const [operation, setOperation] = useState<{ pending: boolean; error?: string }>({ pending: false });
  const scope = JSON.stringify([did, node]);
  const [snapshot, setSnapshot] = useState<StreamSnapshot & { scope: string }>({ messages: [], connected: false, scope });
  const cache = useQueryClient();
  useLayoutEffect(() => { identity.current = { did, node }; mounted.current = true; return () => { mounted.current = false; }; }, [did, node]);
  const requireSession = useCallback(() => { const oauth = getOAuthSession(); if (!oauth || oauth.did !== did || identity.current.did !== did || identity.current.node !== node || !mounted.current) throw new Error("Your Account Or Node Changed. Reopen Livestream."); return oauth; }, [did, node, getOAuthSession]);
  const streams = useQuery({ queryKey: ["livestream", did, "records"], queryFn: ({ signal }) => listLivestreams(requireSession(), signal), enabled: !!did, retry: false });
  const ingests = useQuery({ queryKey: ["livestream", did, node, "ingests"], queryFn: ({ signal }) => getStreamIngests(node, signal), enabled: !!did, retry: false });
  useEffect(() => {
    if (!did) return;
    let disposed = false, socket: WebSocket | undefined, retry: ReturnType<typeof setTimeout> | undefined;
    const updateSnapshot = (change: (value: StreamSnapshot) => StreamSnapshot) => setSnapshot(previous => ({ ...change(previous.scope === scope ? previous : { messages: [], connected: false }), scope }));
    const connect = () => {
      const url = new URL(`/api/websocket/${encodeURIComponent(did)}`, streamplaceNodeOrigin(node)); url.protocol = "wss:";
      socket = new WebSocket(url);
      socket.onopen = () => { if (!disposed) updateSnapshot(previous => ({ ...previous, connected: true, error: undefined })); };
      socket.onmessage = event => { if (disposed) return; try { const value: unknown = JSON.parse(event.data); updateSnapshot(previous => reduceStreamSnapshot(previous, value, did)); } catch { /* Invalid frames do not replace valid stream data. */ } };
      socket.onerror = () => { if (!disposed) updateSnapshot(previous => ({ ...previous, connected: false, error: "Streamplace Connection Unavailable." })); socket?.close(); };
      socket.onclose = () => { if (!disposed) { updateSnapshot(previous => ({ ...previous, connected: false })); retry = setTimeout(connect, 3000); } };
    };
    connect(); return () => { disposed = true; if (retry) clearTimeout(retry); socket?.close(); };
  }, [did, node, scope]);
  const run = useCallback(async <T,>(name: string, action: (attempt: StreamOperation) => Promise<T>, rkey?: string): Promise<T> => {
    requireSession(); if (locked.current) throw new Error("Wait For The Current Operation."); locked.current = true; setOperation({ pending: true });
    const key = JSON.stringify([did, node, name]); const attempt = attempts.current.get(key) ?? { rkey: rkey ?? TID.nextStr(), createdAt: new Date().toISOString() }; attempts.current.set(key, attempt);
    try { const result = await action({ ...attempt, assertCurrentAccount: () => { requireSession(); } }); requireSession(); attempts.current.delete(key); void cache.invalidateQueries({ queryKey: ["livestream", did, "records"] }).catch(() => undefined); return result; }
    catch (error) { if (mounted.current && identity.current.did === did && identity.current.node === node) setOperation({ pending: true, error: error instanceof Error ? error.message : "Livestream Operation Failed." }); throw error; }
    finally { locked.current = false; if (mounted.current && identity.current.did === did && identity.current.node === node) setOperation(previous => ({ ...previous, pending: false })); }
  }, [cache, did, node, requireSession]);
  return {
    did, streams: streams.data ?? [], loading: streams.isPending, ingests: ingests.data ?? [], snapshot: snapshot.scope === scope ? snapshot : { messages: [], connected: false } as StreamSnapshot, pending: operation.pending,
    error: operation.error ?? streams.error?.message ?? ingests.error?.message,
    generateKey: () => run(`key:${crypto.randomUUID()}`, attempt => generateStreamKey(requireSession(), attempt)),
    save: (input: LivestreamInput, existing?: Livestream) => run(JSON.stringify(["save", input, existing?.uri]), attempt => saveLivestream(requireSession(), node, input, attempt, existing), existing?.uri.split("/").at(-1)),
    end: (stream: Livestream) => run(`end:${stream.uri}`, attempt => endLivestream(requireSession(), stream, attempt), stream.uri.split("/").at(-1)),
    send: (text: string) => run(`chat:${text}`, attempt => sendStreamChat(requireSession(), did!, text, attempt)),
    uploadThumbnail: (file: Blob) => run("thumbnail", () => uploadStreamThumbnail(requireSession(), file, () => { requireSession(); })),
    refresh: () => streams.refetch(),
  };
}
