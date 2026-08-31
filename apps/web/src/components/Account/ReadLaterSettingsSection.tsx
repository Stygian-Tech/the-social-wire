"use client";

import { useMemo, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";

import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import {
  ACCOUNT_PREFERENCES_QUERY_KEY,
  useAccountPreferences,
  useConfiguredReadLaterService,
} from "@/hooks/useReadLaterPreferences";
import { usePDSClient } from "@/hooks/usePDSClient";
import { useSembleCollections } from "@/hooks/useSembleReadLater";
import { requireSembleScopes } from "@/lib/semble";

export function ReadLaterSettingsSection() {
  const { getOAuthSession } = useAuth();
  const pdsClient = usePDSClient();
  const queryClient = useQueryClient();
  const preferences = useAccountPreferences();
  const configured = useConfiguredReadLaterService();
  const collectionsQuery = useSembleCollections();
  const [selectedCollectionOverride, setSelectedCollectionOverride] =
    useState<string | null>(null);
  const selectedCollectionUri =
    selectedCollectionOverride ?? configured.sembleConnection?.collectionUri ?? "";

  const selectedCollection = useMemo(
    () =>
      collectionsQuery.collections.find(
        (collection) => collection.uri === selectedCollectionUri,
      ) ?? null,
    [collectionsQuery.collections, selectedCollectionUri],
  );

  const mutation = useMutation({
    mutationFn: async (input: {
      serviceId: "latr-link" | "semble";
      collectionUri?: string;
    }) => {
      if (!pdsClient) throw new Error("Sign in to change Read Later settings.");
      const current = preferences.data ?? null;
      if (input.serviceId === "latr-link") {
        await pdsClient.upsertPreferences({ readLaterService: "latr-link" }, current);
        return;
      }
      const oauthSession = getOAuthSession();
      if (!oauthSession) throw new Error("Sign in to connect Semble.");
      await requireSembleScopes(oauthSession);
      const collection = collectionsQuery.collections.find(
        (candidate) => candidate.uri === input.collectionUri,
      );
      if (!collection) throw new Error("Choose one of your Semble collections.");
      await pdsClient.upsertPreferences(
        {
          readLaterService: "semble",
          readLaterConnections: {
            ...current?.value.readLaterConnections,
            semble: {
              collectionUri: collection.uri,
              collectionName: collection.name,
              connectedAt:
                current?.value.readLaterConnections?.semble?.connectedAt ??
                new Date().toISOString(),
            },
          },
        },
        current,
      );
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({
        queryKey: ACCOUNT_PREFERENCES_QUERY_KEY,
      });
    },
  });

  return (
    <section className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)]">
      <h2 className="text-sm font-bold">Read Later</h2>
      <p className="mt-1 text-xs leading-5 text-muted-foreground">
        Keep using L@tr.link, or use one of your Semble collections as the Read Later list.
        Switching providers does not delete either provider&apos;s saved data.
      </p>
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <Button
          type="button"
          variant={configured.serviceId === "latr-link" ? "default" : "outline"}
          disabled={mutation.isPending}
          onClick={() => mutation.mutate({ serviceId: "latr-link" })}
        >
          Use L@tr.link
        </Button>
        <Button
          type="button"
          variant={configured.serviceId === "semble" ? "default" : "outline"}
          disabled={mutation.isPending || !selectedCollection}
          onClick={() =>
            mutation.mutate({
              serviceId: "semble",
              collectionUri: selectedCollectionUri,
            })
          }
        >
          Use Semble
        </Button>
      </div>
      <label className="mt-4 grid gap-1.5 text-sm font-medium">
        Semble Collection
        <select
          value={selectedCollectionUri}
          disabled={collectionsQuery.isLoading || mutation.isPending}
          onChange={(event) => setSelectedCollectionOverride(event.target.value)}
          className="h-10 rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <option value="">Choose A Collection</option>
          {collectionsQuery.collections.map((collection) => (
            <option key={collection.uri} value={collection.uri}>
              {collection.name} ({collection.cardCount})
            </option>
          ))}
        </select>
      </label>
      {collectionsQuery.isError ? (
        <p role="alert" className="mt-2 text-sm text-destructive">
          {collectionsQuery.error.message}
        </p>
      ) : null}
      {mutation.error ? (
        <p role="alert" className="mt-2 text-sm text-destructive">
          {mutation.error.message}
        </p>
      ) : null}
      {configured.serviceId === "semble" && configured.sembleConnection ? (
        <p className="mt-3 text-xs text-muted-foreground">
          Read Later currently uses {configured.sembleConnection.collectionName}.
        </p>
      ) : null}
    </section>
  );
}
