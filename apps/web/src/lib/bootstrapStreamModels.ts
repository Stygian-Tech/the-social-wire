import type { EntryListItem } from "@/lib/atprotoClient";
import type {
  PublicationSidebarProjection,
  UnreadCountsAccuracy,
} from "@/lib/publicationProjectionClient";

export type BootstrapStreamEventKind =
  | "sidebarPriority"
  | "sidebarSection"
  | "unreadCounts"
  | "selectedPublication"
  | "entriesPage"
  | "sidebarFolders"
  | "warning"
  | "error"
  | "done";

export type BootstrapEvidenceSource =
  | "live_projection"
  | "projection_cache"
  | "unavailable";

export type BootstrapStreamEvent = {
  kind: BootstrapStreamEventKind;
  sidebarPriority?: PublicationSidebarProjection;
  sidebarSection?: {
    sectionKey: string;
    folderRkey?: string;
    folderUri?: string;
    publications: PublicationSidebarProjection["allPublicationRows"];
    unreadCounts?: Record<string, number>;
    replacePublicationIds?: string[];
    refreshedAt: string;
    sectionGeneration?: number;
  };
  unreadCounts?: {
    counts: Record<string, number>;
    replacePublicationIds?: string[];
    generation?: number;
    accuracy?: UnreadCountsAccuracy;
    countedAt?: string;
  };
  selectedPublication?: { publicationId: string };
  entriesPage?: {
    publicationId: string;
    entries: EntryListItem[];
    cursor?: string;
    source: BootstrapEvidenceSource;
    cachedAt?: string;
    expiresAt?: string;
  };
  sidebarFolders?: {
    folderSections: NonNullable<PublicationSidebarProjection["folderSections"]>;
    allPublicationRows: PublicationSidebarProjection["allPublicationRows"];
  };
  warning?: { message: string };
  error?: { message: string };
  done?: { refreshedAt: string; source?: BootstrapEvidenceSource };
};

export type ParsedBootstrapStreamEvent =
  | { kind: "sidebarPriority"; payload: PublicationSidebarProjection }
  | {
      kind: "sidebarSection";
      payload: {
        sectionKey: string;
        folderRkey?: string;
        folderUri?: string;
        publications: PublicationSidebarProjection["allPublicationRows"];
        unreadCounts?: Record<string, number>;
        replacePublicationIds?: string[];
        refreshedAt: string;
        sectionGeneration?: number;
      };
    }
  | {
      kind: "unreadCounts";
      payload: {
        counts: Record<string, number>;
        replacePublicationIds?: string[];
        generation?: number;
        accuracy?: UnreadCountsAccuracy;
        countedAt?: string;
      };
    }
  | { kind: "selectedPublication"; payload: { publicationId: string } }
  | {
      kind: "entriesPage";
      payload: {
        publicationId: string;
        entries: EntryListItem[];
        cursor?: string;
        source: BootstrapEvidenceSource;
        cachedAt?: string;
        expiresAt?: string;
      };
    }
  | {
      kind: "sidebarFolders";
      payload: {
        folderSections: NonNullable<PublicationSidebarProjection["folderSections"]>;
        allPublicationRows: PublicationSidebarProjection["allPublicationRows"];
      };
    }
  | { kind: "warning"; payload: { message: string } }
  | { kind: "error"; payload: { message: string } }
  | {
      kind: "done";
      payload: { refreshedAt: string; source?: BootstrapEvidenceSource };
    };

function isEvidenceSource(value: unknown): value is BootstrapEvidenceSource {
  return (
    value === "live_projection" ||
    value === "projection_cache" ||
    value === "unavailable"
  );
}

function hasValidEntriesPageEvidence(
  payload: NonNullable<BootstrapStreamEvent["entriesPage"]>
): boolean {
  if (!isEvidenceSource(payload.source)) return false;
  if (payload.source !== "projection_cache") return true;
  if (!payload.cachedAt || !payload.expiresAt) return false;
  const cachedAt = Date.parse(payload.cachedAt);
  const expiresAt = Date.parse(payload.expiresAt);
  return Number.isFinite(cachedAt) && Number.isFinite(expiresAt) && cachedAt < expiresAt;
}

export function parseBootstrapStreamEvent(
  raw: BootstrapStreamEvent
): ParsedBootstrapStreamEvent | null {
  switch (raw.kind) {
    case "sidebarPriority":
      if (!raw.sidebarPriority) return null;
      return { kind: "sidebarPriority", payload: raw.sidebarPriority };
    case "sidebarSection":
      if (!raw.sidebarSection) return null;
      return { kind: "sidebarSection", payload: raw.sidebarSection };
    case "unreadCounts":
      if (!raw.unreadCounts) return null;
      return { kind: "unreadCounts", payload: raw.unreadCounts };
    case "selectedPublication":
      if (!raw.selectedPublication) return null;
      return { kind: "selectedPublication", payload: raw.selectedPublication };
    case "entriesPage":
      if (!raw.entriesPage || !hasValidEntriesPageEvidence(raw.entriesPage)) return null;
      return { kind: "entriesPage", payload: raw.entriesPage };
    case "sidebarFolders":
      if (!raw.sidebarFolders) return null;
      return { kind: "sidebarFolders", payload: raw.sidebarFolders };
    case "warning":
      if (!raw.warning) return null;
      return { kind: "warning", payload: raw.warning };
    case "error":
      if (!raw.error) return null;
      return { kind: "error", payload: raw.error };
    case "done":
      if (!raw.done) return null;
      return { kind: "done", payload: raw.done };
    default:
      return null;
  }
}

export function firstUnreadPriorityPublicationId(args: {
  myPublications: PublicationSidebarProjection["myPublications"];
  subscribedUnfoldered: PublicationSidebarProjection["subscribedUnfoldered"];
  followingTabPublications: PublicationSidebarProjection["followingTabPublications"];
  unreadCounts: Record<string, number>;
}): string | null {
  for (const row of [
    ...args.myPublications,
    ...args.subscribedUnfoldered,
    ...args.followingTabPublications,
  ]) {
    const count = args.unreadCounts[row.publicationId] ?? row.unreadCount ?? 0;
    if (count > 0) return row.publicationId;
  }
  return null;
}
