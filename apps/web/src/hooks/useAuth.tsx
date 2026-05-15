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
  getSession,
  getStoredOAuthDid,
  localLoopbackCanonicalHref,
  pathnameIsOAuthCallbackRoute,
  signIn as authSignIn,
  signOut as authSignOut,
} from "@/lib/auth";

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
  signIn: (handle: string) => Promise<void>;
  signOut: () => Promise<void>;
}

// ── Context ───────────────────────────────────────────────────────────────────

const AuthContext = createContext<AuthContextValue | null>(null);

// ── Provider ──────────────────────────────────────────────────────────────────

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<AuthSession | null>(null);
  const [isLoading, setIsLoading] = useState(
    () =>
      typeof window !== "undefined" &&
      pathnameIsOAuthCallbackRoute(window.location.pathname)
        ? false
        : true
  );

  // Store the OAuthSession in a ref — it manages its own token lifecycle
  // (including DPoP key rotation and token refresh) and doesn't need to be
  // tracked as React state.
  const oauthSessionRef = useRef<OAuthSession | null>(null);

  useEffect(() => {
    if (typeof window === "undefined") return;

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
      const storedDid = getStoredOAuthDid();
      if (storedDid && !cancelled) {
        setSession({ did: storedDid });
      }

      if (!cancelled) setIsLoading(false);

      const oauthSession = await getSession();
      if (!cancelled && oauthSession) {
        oauthSessionRef.current = oauthSession;
        setSession({ did: oauthSession.did });
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
  }, []);

  const handleSignIn = useCallback(async (handle: string) => {
    await authSignIn(handle);
    // Browser redirects — no further code runs here.
  }, []);

  const handleSignOut = useCallback(async () => {
    if (session) {
      await authSignOut(session.did);
      oauthSessionRef.current = null;
      setSession(null);
    }
  }, [session]);

  const applyOAuthSession = useCallback((oauthSession: OAuthSession) => {
    oauthSessionRef.current = oauthSession;
    setSession({ did: oauthSession.did });
    setIsLoading(false);
  }, []);

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
        applyOAuthSession,
        getOAuthSession,
        getAuthFetch,
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
