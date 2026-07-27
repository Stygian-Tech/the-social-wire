"use client";

import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  createAuthFetch,
  clearStoredOAuthSessionHint,
  getSession,
  onOAuthSessionInvalidated,
  localLoopbackCanonicalHref,
  pathnameIsOAuthCallbackRoute,
  signIn as authSignIn,
  signOut as authSignOut,
} from "@/lib/auth";
import {
  DUMMY_VIEWER_DID,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";

// ── Types ─────────────────────────────────────────────────────────────────────

interface AuthSession {
  /** The user's ATProto DID */
  did: string;
}

type AuthFetch = (url: string, init?: RequestInit) => Promise<Response>;

interface AuthContextValue {
  /** Minimal serialisable session info, or null when signed out */
  session: AuthSession | null;
  /** True while the initial session restore is in progress */
  isLoading: boolean;
  /**
   * Bumps whenever the in-memory OAuth handle may change. Included in {@link usePDSClient}
   * deps so a fresh {@link PDSClient} builds after IndexedDB/session sync fixes.
   */
  oauthSessionReloadSeq: number;
  /**
   * Sets the OAuth session after a successful OAuth callback (client-side callback route).
   * Required because handleCallback resolves outside AuthProvider lifecycle;
   * without this, IndexedDB holds the session but context stays null until a full reload.
   */
  applyOAuthSession: (oauthSession: OAuthSession) => void;
  /**
   * Returns the raw OAuthSession for constructing PDSClient.
   * Returns null when not signed in.
   */
  getOAuthSession: () => OAuthSession | null;
  /**
   * Returns a DPoP-signed fetch function for the current session.
   * Suitable for use with getServiceClient().
   * Returns null when not signed in.
   */
  getAuthFetch: () => AuthFetch | null;
  /**
   * Clear the cached OAuthSession instance and reload from IndexedDB via `getSession()`.
   * Use after PDS errors that indicate oauth-client-browser storage/session drift.
   *
   * Returns true when a session was restored; false when none (caller may prompt re-login).
   */
  reconcileOAuthSession: () => Promise<boolean>;
  signIn: (handle: string) => Promise<void>;
  signOut: () => Promise<void>;
}

// ── Context ───────────────────────────────────────────────────────────────────

const AuthContext = createContext<AuthContextValue | null>(null);

// ── Provider ──────────────────────────────────────────────────────────────────

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();
  const [session, setSession] = useState<AuthSession | null>(() =>
    dummyReaderDataEnabled ? { did: DUMMY_VIEWER_DID } : null
  );
  const [oauthSessionReloadSeq, setOAuthSessionReloadSeq] = useState(0);
  const [isLoading, setIsLoading] = useState(
    () =>
      !dummyReaderDataEnabled &&
      typeof window !== "undefined" &&
      pathnameIsOAuthCallbackRoute(window.location.pathname)
        ? false
        : !dummyReaderDataEnabled
  );

  // Store the OAuthSession in a ref — it manages its own token lifecycle
  // (including DPoP key rotation and token refresh) and doesn't need to be
  // tracked as React state.
  const oauthSessionRef = useRef<OAuthSession | null>(null);

  const bumpOAuthReloadSeq = useCallback(() => {
    setOAuthSessionReloadSeq((n) => n + 1);
  }, []);

  const reconcileOAuthSession = useCallback(async (): Promise<boolean> => {
    oauthSessionRef.current = null;
    bumpOAuthReloadSeq();

    try {
      const oauthSession = await getSession();
      if (oauthSession) {
        oauthSessionRef.current = oauthSession;
        setSession({ did: oauthSession.did });
        bumpOAuthReloadSeq();
        return true;
      }

      clearStoredOAuthSessionHint();
      setSession(null);
      return false;
    } catch {
      clearStoredOAuthSessionHint();
      setSession(null);
      return false;
    }
  }, [bumpOAuthReloadSeq]);

  useEffect(
    () =>
      onOAuthSessionInvalidated(() => {
        oauthSessionRef.current = null;
        setSession(null);
        setIsLoading(false);
        bumpOAuthReloadSeq();
      }),
    [bumpOAuthReloadSeq]
  );

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (dummyReaderDataEnabled) return;

    if (pathnameIsOAuthCallbackRoute(window.location.pathname)) {
      return;
    }

    const canonicalHref = localLoopbackCanonicalHref(window.location.href);
    if (canonicalHref) {
      window.location.replace(canonicalHref);
      return;
    }

    let cancelled = false;

    void (async () => {
      const oauthSession = await getSession();
      if (!cancelled && oauthSession) {
        oauthSessionRef.current = oauthSession;
        setSession({ did: oauthSession.did });
        setOAuthSessionReloadSeq((n) => n + 1);
      } else if (!cancelled) {
        clearStoredOAuthSessionHint();
        setSession(null);
      }
    })()
      .catch((err) => {
        console.error("OAuth session restore failed:", err);
      })
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [dummyReaderDataEnabled]);

  const handleSignIn = useCallback(async (handle: string) => {
    if (dummyReaderDataEnabled) {
      setSession({ did: DUMMY_VIEWER_DID });
      setIsLoading(false);
      return;
    }
    await authSignIn(handle);
    // Browser redirects — no further code runs here.
  }, [dummyReaderDataEnabled]);

  const handleSignOut = useCallback(async () => {
    if (!session) return;

    if (dummyReaderDataEnabled) {
      setSession({ did: DUMMY_VIEWER_DID });
      setIsLoading(false);
      return;
    }

    const did = session.did;

    // Drop the in-memory session first so hooks abort in-flight OAuth work
    // before we revoke credentials at the authorization server.
    oauthSessionRef.current = null;
    setSession(null);
    bumpOAuthReloadSeq();

    await new Promise<void>((resolve) => {
      setTimeout(resolve, 0);
    });

    await authSignOut(did);
  }, [bumpOAuthReloadSeq, dummyReaderDataEnabled, session]);

  const applyOAuthSession = useCallback((oauthSession: OAuthSession) => {
    oauthSessionRef.current = oauthSession;
    setSession({ did: oauthSession.did });
    setIsLoading(false);
    bumpOAuthReloadSeq();
  }, [bumpOAuthReloadSeq]);

  const getOAuthSession = useCallback((): OAuthSession | null => {
    return oauthSessionRef.current;
  }, []);

  const getAuthFetch = useCallback((): AuthFetch | null => {
    const s = oauthSessionRef.current;
    if (!s) return null;
    return createAuthFetch(s);
  }, []);

  return (
    <AuthContext.Provider
      value={{
        session,
        isLoading,
        oauthSessionReloadSeq,
        applyOAuthSession,
        getOAuthSession,
        getAuthFetch,
        reconcileOAuthSession,
        signIn: handleSignIn,
        signOut: handleSignOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

// ── Hook ──────────────────────────────────────────────────────────────────────

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within <AuthProvider>");
  return ctx;
}
