import { Avatar } from "@/components/shared/Avatar";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

export function PublicationLeadingAvatar({
  publication,
}: {
  publication: DiscoveredPublication;
}) {
  return (
    <Avatar
      src={publication.iconUrl ?? publication.avatarUrl}
      alt=""
      size={20}
      className="shrink-0"
    />
  );
}
