"use client";

import { useEffect, useRef } from "react";
import { useAuth } from "@/hooks/useAuth";
import { usePDSClient } from "@/hooks/usePDSClient";
import {
  latrLexiconMigrationChanged,
  migrateLatrLexiconsViaGateway,
} from "@/lib/latrLexiconMigration";
import { lexiconMigrationChanged } from "@/lib/pdsClient";

/**
 * Runs one-time PDS lexicon migration after OAuth session restore.
 * Copies legacy `com.thesocialwire.*` rows to `app.thesocialwire.*` and deletes the old records.
 * Also migrates legacy `com.latr.*` read-later rows to `link.latr.*` via the L@tr gateway.
 */
export function LexiconMigrationRunner() {
  const client = usePDSClient();
  const { getOAuthSession } = useAuth();
  const migratedForDidRef = useRef<string | null>(null);

  useEffect(() => {
    if (!client) {
      migratedForDidRef.current = null;
      return;
    }

    const did = client.viewerDid;
    if (migratedForDidRef.current === did) return;
    migratedForDidRef.current = did;

    void (async () => {
      try {
        const summary = await client.migrateLegacyLexiconsIfNeeded();
        if (lexiconMigrationChanged(summary)) {
          console.info("Migrated legacy Social Wire lexicons", summary);
        }

        const oauthSession = getOAuthSession();
        if (oauthSession) {
          const latrSummary = await migrateLatrLexiconsViaGateway(oauthSession);
          if (latrLexiconMigrationChanged(latrSummary)) {
            console.info("Migrated legacy L@tr lexicons", latrSummary);
          }
        }
      } catch (err) {
        console.warn("Legacy lexicon migration failed:", err);
        migratedForDidRef.current = null;
      }
    })();
  }, [client, getOAuthSession]);

  return null;
}
