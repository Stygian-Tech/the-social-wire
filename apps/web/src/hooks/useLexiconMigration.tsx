"use client";

import { useEffect, useRef } from "react";
import { usePDSClient } from "@/hooks/usePDSClient";
import { lexiconMigrationChanged } from "@/lib/pdsClient";

const completedMigrationDids = new Set<string>();
const inFlightMigrationDids = new Set<string>();

/**
 * Runs one-time PDS lexicon migration after OAuth session restore.
 * Copies legacy `com.thesocialwire.*` rows to `app.thesocialwire.*` and deletes the old records.
 * L@tr bookmark migration is owned by the authenticated Read Later load through
 * `link.latr.bookmarks.migrateLegacy`.
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
    if (
      migratedForDidRef.current === did ||
      completedMigrationDids.has(did) ||
      inFlightMigrationDids.has(did)
    ) {
      return;
    }
    migratedForDidRef.current = did;
    inFlightMigrationDids.add(did);

    void (async () => {
      try {
        const summary = await client.migrateLegacyLexiconsIfNeeded();
        if (lexiconMigrationChanged(summary)) {
          console.info("Migrated legacy Social Wire lexicons", summary);
        }

        completedMigrationDids.add(did);
      } catch (err) {
        console.warn("Legacy lexicon migration failed:", err);
        migratedForDidRef.current = null;
      } finally {
        inFlightMigrationDids.delete(did);
      }
    })();
  }, [client]);

  return null;
}
