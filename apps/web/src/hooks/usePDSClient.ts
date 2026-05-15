"use client";

import { useMemo } from "react";
import { PDSClient } from "@/lib/pdsClient";
import { useAuth } from "./useAuth";

/**
 * Returns a memoised PDSClient for the current session, or null when signed out.
 *
 * The OAuthSession is stable (stored in a ref inside AuthProvider), so the
 * returned PDSClient instance is stable across renders unless the user signs
 * in or out.
 */
export function usePDSClient(): PDSClient | null {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();

  return useMemo(() => {
    if (!session) return null;
    const oauthSession = getOAuthSession();
    if (!oauthSession) return null;
    return new PDSClient(oauthSession, session.did);
    // oauthSessionReloadSeq: same DID can get a refreshed OAuthSession (restore / reconcile).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.did, oauthSessionReloadSeq]); // DID + OAuth handle identity
}
