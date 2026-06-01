"use client";

import { useEffect, useRef } from "react";
import { usePDSClient } from "@/hooks/usePDSClient";
import { lexiconMigrationChanged } from "@/lib/pdsClient";

/**
 * Runs one-time PDS lexicon migration after OAuth session restore.
 * Copies legacy `com.thesocialwire.*` rows to `app.thesocialwire.*` and deletes the old records.
 */
export function LexiconMigrationRunner() {
  const client = usePDSClient();
  const migratedForDidRef = useRef<string | null>(null);

  useEffect(() => {
    if (!client) {
      migratedForDidRef.current = null;
      return;
    }

    const did = client.viewerDid;
    if (migratedForDidRef.current === did) return;
    migratedForDidRef.current = did;

    void client
      .migrateLegacyLexiconsIfNeeded()
      .then((summary) => {
        if (lexiconMigrationChanged(summary)) {
          console.info("Migrated legacy Social Wire lexicons", summary);
        }
      })
      .catch((err) => {
        console.warn("Legacy lexicon migration failed:", err);
        migratedForDidRef.current = null;
      });
  }, [client]);

  return null;
}
