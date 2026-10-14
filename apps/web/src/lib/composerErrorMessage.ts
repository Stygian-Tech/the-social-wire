import { socialErrorMessage } from "./blueskySocialClient";

export function composerErrorMessage(error: unknown, thread = false): string {
  const message = socialErrorMessage(error);
  if (message !== "This social feed could not be loaded. Please retry.") return message;
  if (error instanceof Error && /^(GIF|Photo|Draft|This GIF|Finish Preparing|Invalid|Attachments|A Thread Post Changed|Your Account Changed)/i.test(error.message)) return error.message;
  return thread ? "Your Thread Could Not Be Finished. Retry to Continue Without Reposting Published Posts." : "Your post could not be published. Please try again.";
}
