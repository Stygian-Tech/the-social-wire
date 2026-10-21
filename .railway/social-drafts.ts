import { bucket, defineRailway, project } from "railway/iac";

// Keep this rollout independent of the indexing partial and existing App View
// config-as-code. App View receives bucket reference variables at deployment.
export const partial = "social-draft-storage";

export default defineRailway((context) => project("The Social Wire", {
  resources: context.isEnvironment("dev")
    ? [bucket("Social Draft Attachments", { region: "sjc" })]
    : context.isEnvironment("production")
      ? [bucket("Social Draft Attachments Production", { region: "sjc" })]
      : [],
}));
