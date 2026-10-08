import { afterEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, render } from "@testing-library/react";
import type { ReactNode } from "react";

import * as AuthHook from "@/hooks/useAuth";
import * as AppearanceHook from "@/hooks/useAppearance";
import * as PDSHook from "@/hooks/usePDSClient";
import { Providers } from "@/app/providers";
import type { PDSClient } from "@/lib/pdsClient";

const restorations: Array<() => void> = [];

afterEach(() => {
  cleanup();
  restorations.splice(0).forEach((restore) => restore());
});

it("restoring a signed-in viewer does not register a legacy PDS migration", async () => {
  const did = "did:plc:restored-provider-viewer";
  let session: { did: string } | null = null;
  const legacyRecords = ["legacy-folder", "legacy-publication-preferences"];
  const canonicalRecords = ["current-folder", "current-preferences"];
  // This sentinel represents the old runner's destructive side effect. Restoring
  // the provider must leave both record sets untouched without invoking it.
  const migrateLegacyLexiconsIfNeeded = mock(async () => {
    canonicalRecords.push(...legacyRecords);
    legacyRecords.splice(0);
    return {
      foldersCopied: 1,
      publicationPrefsCopied: 1,
      preferencesCopied: 0,
      foldersDeleted: 1,
      publicationPrefsDeleted: 1,
      preferencesDeleted: 0,
    };
  });
  const authProvider = spyOn(AuthHook, "AuthProvider").mockImplementation(
    ({ children }: { children: ReactNode }) => <>{children}</>,
  );
  const appearance = spyOn(AppearanceHook, "AppearanceProvider").mockImplementation(
    ({ children }: { children: ReactNode }) => <>{children}</>,
  );
  const auth = spyOn(AuthHook, "useAuth").mockImplementation(
    () => ({ session }) as ReturnType<typeof AuthHook.useAuth>,
  );
  const client = spyOn(PDSHook, "usePDSClient").mockImplementation(() =>
    session
      ? ({ viewerDid: did, migrateLegacyLexiconsIfNeeded } as unknown as PDSClient)
      : null,
  );
  restorations.push(
    () => authProvider.mockRestore(),
    () => appearance.mockRestore(),
    () => auth.mockRestore(),
    () => client.mockRestore(),
  );

  const reader = <Providers><span>Reader</span></Providers>;
  const view = render(reader);
  await act(async () => {
    session = { did };
    view.rerender(<Providers><span>Reader</span></Providers>);
  });

  expect(migrateLegacyLexiconsIfNeeded).not.toHaveBeenCalled();
  expect(client).not.toHaveBeenCalled();
  expect(legacyRecords).toEqual(["legacy-folder", "legacy-publication-preferences"]);
  expect(canonicalRecords).toEqual(["current-folder", "current-preferences"]);
});
