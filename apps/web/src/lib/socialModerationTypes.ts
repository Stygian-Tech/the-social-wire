import type { ModerationOpts } from "@atproto/api";

export type SocialModerationOpts = ModerationOpts & {
  labelerAvatars?: Record<string, string>;
};
