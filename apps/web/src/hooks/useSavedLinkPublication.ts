"use client";

import { useMemo } from "react";

import { useSidebarProjection } from "@/contexts/PublicationSidebarContext";
import type { MergedLatrSave } from "@/lib/pdsClient";
import { sidebarPublicationRows } from "@/lib/publicationProjectionClient";
import {
  resolveSavedLinkPublicationWithSidebar,
  type SavedLinkPublication,
} from "@/lib/savedLinkPublication";

export function useSavedLinkPublication(
  row: MergedLatrSave | null
): SavedLinkPublication | null {
  const { publicationSidebarProjection } = useSidebarProjection();

  return useMemo(() => {
    if (!row) return null;
    const sidebarRows = publicationSidebarProjection
      ? sidebarPublicationRows(publicationSidebarProjection)
      : [];
    return resolveSavedLinkPublicationWithSidebar(row, sidebarRows);
  }, [publicationSidebarProjection, row]);
}
