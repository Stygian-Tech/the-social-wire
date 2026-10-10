"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ArticleDraft } from "@/lib/articles/articleDraftTypes";
import { deleteArticleDraft, getArticleDraft, listArticleDrafts, saveArticleDraft } from "@/lib/articles/articleDraftStorage";

const PRIVATE_DRAFT_STATUS = "Drafts Are Private to This Browser";
export function useArticleDrafts(did: string) {
  const [drafts, setDrafts] = useState<ArticleDraft[]>([]);
  const [draft, setDraft] = useState<ArticleDraft>();
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState(PRIVATE_DRAFT_STATUS);
  const [error, setError] = useState<string>();
  const [boundDid] = useState(did);
  const activeDid = useRef(did);
  useLayoutEffect(() => { activeDid.current = did; }, [did]);
  const current = useRef<ArticleDraft | undefined>(undefined);
  const pending = useRef(Promise.resolve());
  const versions = useRef(new Map<string, number>());
  const dirty = useRef(false);
  const editVersion = useRef(0);
  const intent = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const mounted = useRef(true);
  const available = useCallback(() => mounted.current && activeDid.current === boundDid, [boundDid]);
  const requireViewer = useCallback(() => {
    if (did !== boundDid) throw new Error("Your account changed. Reopen Articles before editing private drafts.");
  }, [did, boundDid]);
  const reportFailure = useCallback((failure: unknown) => {
    if (available()) {
      setStatus("Not Saved");
      setError(failure instanceof Error ? failure.message : "The draft could not be saved. Your edits remain open.");
    }
  }, [available]);

  const persist = useCallback(async () => {
    requireViewer();
    if (timer.current) clearTimeout(timer.current);
    const snapshot = current.current;
    // Keep the actual rejecting promise as the navigation barrier. A selection
    // waiting for an in-flight save must not proceed after that save fails.
    if (!snapshot || !dirty.current) { await pending.current; return; }
    const snapshotVersion = editVersion.current;
    dirty.current = false;
    if (available()) setStatus("Saving…");
    const write = pending.current.catch(() => undefined).then(async () => {
      const saved = await saveArticleDraft(did, { ...snapshot, revision: versions.current.get(snapshot.id) ?? snapshot.revision });
      versions.current.set(saved.id, saved.revision ?? 0);
      if (current.current?.id === saved.id) {
        current.current = { ...current.current, revision: saved.revision };
        if (editVersion.current === snapshotVersion) dirty.current = false;
        if (available()) setDraft(current.current);
      }
      if (available()) {
        setDrafts(rows => [saved, ...rows.filter(row => row.id !== saved.id)]);
        setStatus(dirty.current ? "Unsaved Changes" : pending.current === write ? "Saved in This Browser" : "Saving…");
        setError(undefined);
      }
    });
    pending.current = write;
    try { await write; }
    catch (failure) {
      if (current.current?.id === snapshot.id) dirty.current = true;
      reportFailure(failure);
      throw failure;
    }
  }, [did, requireViewer, reportFailure, available]);

  const update = useCallback((patch: Partial<ArticleDraft>) => {
    requireViewer();
    if (!current.current) return;
    editVersion.current++;
    current.current = { ...current.current, ...patch, updatedAt: new Date().toISOString() };
    setDraft(current.current);
    dirty.current = true;
    setStatus("Unsaved Changes");
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => { void persist().catch(() => {}); }, 800);
  }, [persist, requireViewer]);

  const select = useCallback(async (id: string) => {
    requireViewer();
    const selection = ++intent.current;
    const selectedVersion = editVersion.current;
    try {
      await persist();
      const saved = await getArticleDraft(did, id);
      if (!available() || selection !== intent.current || selectedVersion !== editVersion.current) return;
      if (!saved) throw new Error("This draft is no longer available. Refresh the draft list.");
      versions.current.set(saved.id, saved.revision ?? 0);
      current.current = saved; dirty.current = false;
      setDraft(saved); setStatus("Saved in This Browser"); setError(undefined);
    } catch (failure) { if (selection === intent.current) reportFailure(failure); throw failure; }
  }, [did, persist, requireViewer, reportFailure, available]);

  const create = useCallback(async (publicationUri = "") => {
    requireViewer();
    const creation = ++intent.current;
    const selectedVersion = editVersion.current;
    try {
      await persist();
      if (selectedVersion !== editVersion.current) throw new Error("Your draft changed while saving. Save those edits before creating another draft.");
      const now = new Date().toISOString();
      const saved = await saveArticleDraft(did, { id: crypto.randomUUID(), title: "", markdown: "", excerpt: "", path: "", tags: [], publicationUri, createdAt: now, updatedAt: now, assets: [] });
      if (!available()) return saved;
      versions.current.set(saved.id, saved.revision ?? 0);
      setDrafts(rows => [saved, ...rows.filter(row => row.id !== saved.id)]);
      if (creation === intent.current && selectedVersion === editVersion.current) {
        current.current = saved; dirty.current = false;
        setDraft(saved); setStatus("Saved in This Browser"); setError(undefined);
      }
      return saved;
    } catch (failure) { if (creation === intent.current) reportFailure(failure); throw failure; }
  }, [did, persist, requireViewer, reportFailure, available]);

  const remove = useCallback(async (id: string) => {
    requireViewer();
    const removal = ++intent.current;
    const selectedVersion = editVersion.current;
    try {
      await persist();
      if (selectedVersion !== editVersion.current) throw new Error("Your draft changed while saving. Save those edits before deleting a draft.");
      await deleteArticleDraft(did, id);
      versions.current.delete(id);
      if (!available()) return;
      setDrafts(rows => rows.filter(row => row.id !== id));
      if (current.current?.id === id && removal === intent.current) { current.current = undefined; setDraft(undefined); dirty.current = false; }
    } catch (failure) { if (removal === intent.current) reportFailure(failure); throw failure; }
  }, [did, persist, requireViewer, reportFailure, available]);

  useEffect(() => {
    if (did !== boundDid) return;
    mounted.current = true;
    let cancelled = false;
    const loadIntent = intent.current;
    void listArticleDrafts(did).then(rows => {
      if (cancelled || loadIntent !== intent.current) return;
      setDrafts(rows);
      if (rows[0]) { current.current = rows[0]; versions.current.set(rows[0].id, rows[0].revision ?? 0); setDraft(rows[0]); }
    }).catch(failure => { if (!cancelled && loadIntent === intent.current) setError(failure instanceof Error ? failure.message : "Private drafts could not be loaded."); }).finally(() => { if (!cancelled) setLoading(false); });
    const onHide = () => { if (document.visibilityState === "hidden") void persist().catch(() => {}); };
    document.addEventListener("visibilitychange", onHide);
    return () => { cancelled = true; mounted.current = false; document.removeEventListener("visibilitychange", onHide); void persist().catch(() => {}); };
  }, [did, persist, boundDid]);
  // The workspace keys this hook by DID. Defensively hide and reject an in-place
  // account change rather than ever persisting another account's private draft.
  const sameViewer = did === boundDid;
  return { drafts: sameViewer ? drafts : [], draft: sameViewer ? draft : undefined, loading, status, error, update, persist, select, create, remove };
}
