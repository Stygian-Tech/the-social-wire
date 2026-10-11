export type LiveDestination = "blog" | "bluesky" | "both";
export type LiveReference = { uri: string; cid: string };
export type LiveUpdate = { id: string; createdAt: string; text: string; articleRef?: LiveReference; postRef?: LiveReference };
export type LiveEvent = {
  $type: "app.thesocialwire.liveEvent";
  uri: string; cid: string; title: string; tags: string[]; destination: LiveDestination;
  publicationUri?: string; sourceEvent?: LiveReference; startsAt?: string; endsAt?: string; articleRef?: LiveReference; articleUrl?: string;
  threadRoot?: LiveReference; threadLast?: LiveReference;
  createdAt: string; updatedAt: string; entries: LiveUpdate[];
};
export type CreateLiveEventInput = Pick<LiveEvent, "title" | "tags" | "destination" | "publicationUri" | "sourceEvent" | "startsAt" | "endsAt">;
export type LiveEventInput = CreateLiveEventInput;
