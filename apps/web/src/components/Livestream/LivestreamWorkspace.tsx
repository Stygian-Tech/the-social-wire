"use client";
import { useAuth } from "@/hooks/useAuth";
import { LivestreamAccountWorkspace } from "./LivestreamAccountWorkspace";
export function LivestreamWorkspace() {
  const { session } = useAuth();
  return session ? <LivestreamAccountWorkspace key={session.did} /> : null;
}
