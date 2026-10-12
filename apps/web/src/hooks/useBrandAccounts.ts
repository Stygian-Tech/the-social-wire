"use client";

import { useProEntitlements } from "@/hooks/useProEntitlements";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { listBrandAccounts, onBrandAccountsChanged, restoreBrandAccount } from "@/lib/brandAccounts/brandAccountSessions";
import { getStoredOAuthDid } from "@/lib/auth";

export function useBrandAccounts(ownerDid: string) {
  const { isPro } = useProEntitlements();
  const [accounts, setAccounts] = useState(() => ({ ownerDid, dids: listBrandAccounts(ownerDid) }));
  useEffect(() => { const update = () => setAccounts({ ownerDid, dids: listBrandAccounts(ownerDid) }); update(); return onBrandAccountsChanged(update); }, [ownerDid]);
  return isPro && accounts.ownerDid === ownerDid ? accounts.dids : [];
}

/** OAuth objects remain in memory, outside the persisted React Query cache. */
export function useBrandAccountSession(ownerDid: string, brandDid: string) {
  const { isPro } = useProEntitlements();
  const access = useRef(isPro);
  useLayoutEffect(() => { access.current = isPro; }, [isPro]);
  const epoch = useRef({ value: 0 });
  const current = useRef({ ownerDid, brandDid });
  const [connection, setConnection] = useState<{ scope: string; session?: OAuthSession; error?: string }>({ scope: "" });
  const [retry, setRetry] = useState(0);
  const scope = JSON.stringify([ownerDid, brandDid, retry]);
  useLayoutEffect(() => { const state = epoch.current; current.current = { ownerDid, brandDid }; state.value++; return () => { state.value++; }; }, [ownerDid, brandDid]);
  useEffect(() => {
    const state = epoch.current;
    const generation = ++state.value;
    if (!isPro) return;
    void restoreBrandAccount(ownerDid, brandDid).then(session => {
      if (epoch.current.value !== generation) return;
      if (session.did !== brandDid) throw new Error("The Linked Account Identity Does Not Match.");
      setConnection({ scope, session });
    }).catch(error => { if (epoch.current.value === generation) setConnection({ scope, error: error instanceof Error ? error.message : "This Brand Account Could Not Be Restored." }); });
    return () => { state.value++; };
  }, [ownerDid, brandDid, scope, isPro]);
  useEffect(() => onBrandAccountsChanged(() => setRetry(value => value + 1)), []);
  const session = isPro && connection.scope === scope ? connection.session : undefined;
  function assertCurrentActor() {
    if (!access.current || !session || getStoredOAuthDid() !== ownerDid || current.current.ownerDid !== ownerDid || current.current.brandDid !== brandDid || !listBrandAccounts(ownerDid).includes(brandDid)) throw new Error("The Acting Account Changed. Reopen Brand Accounts.");
    if (session.did !== brandDid || connection.scope !== scope) throw new Error("The Acting Account Changed. Reopen Brand Accounts.");
  }
  const generation = epoch.current.value;
  return { session, error: connection.scope === scope ? connection.error : undefined, retry: () => setRetry(value => value + 1), assertCurrentActor: () => { if (generation !== epoch.current.value) throw new Error("The Acting Account Changed. Reopen Brand Accounts."); assertCurrentActor(); }, generation: retry };
}
