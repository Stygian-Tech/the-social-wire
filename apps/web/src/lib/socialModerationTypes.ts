import type { ModerationOpts } from "@atproto/api";

export type SocialModerationOpts = ModerationOpts & {
  labelerAvatars?: Record<string, string>;
  labelerProfiles?: Record<string, { displayName?: string; handle: string }>;
};
