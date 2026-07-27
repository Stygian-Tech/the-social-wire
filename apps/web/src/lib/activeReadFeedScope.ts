import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";

export type ActiveReadFeedScope = {
  publications: DiscoveredPublication[];
  gatewayScope: GatewayMarkAllReadScope;
};

export function activeReadFeedScope({
  folderRkey,
  folderPublications,
  selectedPublication,
  selectedTopLevelFeed,
  subscribedPublications,
  followingPublications,
}: {
  folderRkey: string | null;
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
    };
  }
  if (selectedPublication) {
    return {
      publications: [selectedPublication],
      gatewayScope: {
        kind: "publication",
        publicationId: selectedPublication.publicationId,
      },
    };
  }
  if (selectedTopLevelFeed === "following") {
    return {
      publications: followingPublications,
      gatewayScope: { kind: "following" },
    };
  }
  return {
    publications: subscribedPublications,
    gatewayScope: { kind: "subscribed" },
  };
}
