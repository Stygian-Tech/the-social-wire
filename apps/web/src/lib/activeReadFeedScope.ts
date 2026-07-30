import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";

export type ActiveReadFeedScope = {
  publications: DiscoveredPublication[];
  gatewayScope: GatewayMarkAllReadScope;
  displayName: string;
};

export function activeReadFeedScope({
  folderRkey,
  folderName,
  folderPublications,
  selectedPublication,
  selectedTopLevelFeed,
  subscribedPublications,
  followingPublications,
}: {
  folderRkey: string | null;
  folderName?: string;
  folderPublications: DiscoveredPublication[];
  selectedPublication?: DiscoveredPublication;
  selectedTopLevelFeed: "subscribed" | "following";
  subscribedPublications: DiscoveredPublication[];
  followingPublications: DiscoveredPublication[];
}): ActiveReadFeedScope {
  if (folderRkey) {
    return {
      publications: folderPublications,
      gatewayScope: { kind: "folder", folderRkey },
      displayName: folderName?.trim() || "",
    };
  }
  if (selectedPublication) {
    return {
      publications: [selectedPublication],
      gatewayScope: {
        kind: "publication",
        publicationId: selectedPublication.publicationId,
      },
      displayName: selectedPublication.title,
    };
  }
  if (selectedTopLevelFeed === "following") {
    return {
      publications: followingPublications,
      gatewayScope: { kind: "following" },
      displayName: "Following",
    };
  }
  return {
    publications: subscribedPublications,
    gatewayScope: { kind: "subscribed" },
    displayName: "Subscribed",
  };
}
