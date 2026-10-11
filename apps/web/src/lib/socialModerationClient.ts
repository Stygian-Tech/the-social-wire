import { AppBskyLabelerDefs, interpretLabelValueDefinitions, type AppBskyActorDefs, type InterpretedLabelValueDefinition, type LabelPreference, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent, getBlueskySocialCatalog } from "@/lib/blueskySocialClient";

export type SocialLabeler = {
  did: string;
  profile: AppBskyActorDefs.ProfileViewDetailed;
  definitions: InterpretedLabelValueDefinition[];
};

export function localizedSocialLabel(definition: InterpretedLabelValueDefinition, languages: readonly string[] = ["en"]) {
  const locale = languages.map(language => definition.locales.find(item => item.lang.toLowerCase() === language.toLowerCase()) ?? definition.locales.find(item => item.lang.toLowerCase() === language.split("-")[0].toLowerCase())).find(Boolean)
    ?? definition.locales.find(item => item.lang === "en") ?? definition.locales[0];
  return { name: locale?.name || definition.identifier, description: locale?.description || "" };
}

export async function getSocialLabeler(session: OAuthSession, actor: string, signal?: AbortSignal): Promise<SocialLabeler> {
  const value = actor.trim().replace(/^@/, "");
  if (!value || /[\s/?#]/.test(value)) throw new Error("Enter a labeler handle or DID.");
  const agent = createAuthenticatedAppViewAgent(session);
  const preferences = await agent.getPreferences();
  signal?.throwIfAborted();
  agent.configureLabelers(preferences.moderationPrefs.labelers.map(labeler => labeler.did));
  const profile = await agent.app.bsky.actor.getProfile({ actor: value }, { signal });
  signal?.throwIfAborted();
  const services = await agent.app.bsky.labeler.getServices({ dids: [profile.data.did], detailed: true }, { signal });
  signal?.throwIfAborted();
  const service = services.data.views.filter(AppBskyLabelerDefs.isLabelerViewDetailed).find(view => view.creator.did === profile.data.did);
  if (!service) throw new Error("This account does not publish a labeler service.");
  return { did: profile.data.did, profile: profile.data, definitions: interpretLabelValueDefinitions(service) };
}

export async function getSocialModerationSettings(session: OAuthSession, signal?: AbortSignal) {
  const catalog = await getBlueskySocialCatalog(session, signal);
  const mandatory = createAuthenticatedAppViewAgent(session).appLabelers;
  const subscribed = catalog.moderation.prefs.labelers.map(item => item.did);
  const dids = [...new Set([...mandatory, ...subscribed])];
  const labelers = await Promise.all(dids.map(async did => ({ ...await getSocialLabeler(session, did, signal), mandatory: mandatory.includes(did), subscribed: subscribed.includes(did) })));
  signal?.throwIfAborted();
  return { moderation: catalog.moderation, labelers };
}

export function socialLabelVisibility(definition: InterpretedLabelValueDefinition, moderation: ModerationOpts): { visibility: LabelPreference; disabled: boolean } {
  const adultDisabled = definition.flags.includes("adult") && !moderation.prefs.adultContentEnabled;
  const override = moderation.prefs.labelers.find(item => item.did === definition.definedBy)?.labels[definition.identifier];
  return {
    visibility: adultDisabled ? "hide" : !definition.configurable ? definition.defaultSetting : override ?? moderation.prefs.labels[definition.identifier] ?? definition.defaultSetting,
    disabled: adultDisabled || !definition.configurable,
  };
}

export type SocialLabelerChange = { type: "subscribe"; did: string } | { type: "unsubscribe"; did: string } | { type: "label"; did: string; label: string; visibility: LabelPreference };

export async function changeSocialLabeler(session: OAuthSession, change: SocialLabelerChange) {
  const agent = createAuthenticatedAppViewAgent(session);
  if (change.type === "unsubscribe") {
    if (agent.appLabelers.includes(change.did)) throw new Error("This labeler is required by The Social Wire.");
    await agent.removeLabeler(change.did);
  } else {
    const service = await getSocialLabeler(session, change.did);
    if (service.did !== change.did) throw new Error("The labeler account changed. Try again.");
    if (change.type === "subscribe") await agent.addLabeler(change.did);
    else {
      const preferences = await agent.getPreferences();
      const definition = service.definitions.find(item => item.identifier === change.label);
      if (!definition) throw new Error("This label is no longer available.");
      if (!agent.appLabelers.includes(change.did) && !preferences.moderationPrefs.labelers.some(item => item.did === change.did)) throw new Error("Subscribe to this labeler before changing its labels.");
      if (!["ignore", "warn", "hide"].includes(change.visibility)) throw new Error("Choose Show, Warn, or Hide.");
      if (socialLabelVisibility(definition, { userDid: session.did, prefs: preferences.moderationPrefs }).disabled) throw new Error("This label’s visibility cannot be changed.");
      await agent.setContentLabelPref(change.label, change.visibility, change.did);
    }
  }
}
