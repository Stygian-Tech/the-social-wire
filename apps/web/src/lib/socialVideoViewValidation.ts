import type { Agent } from "@atproto/api";

/** Accept upstream video descriptions without changing authoring or safety schemas. */
export function configureSocialVideoViewValidation(agent: Agent): void {
  const id = "app.bsky.embed.video";
  const schema = agent.lex.get(id);
  if (!schema) return;
  // Lexicon documents are shared by SDK agents: never edit the original.
  const video = structuredClone(schema);
  const view = video.defs.view;
  if (view?.type !== "object") return;
  const alt = view.properties.alt;
  if (alt?.type !== "string") return;
  // Some AppView posts exceed the record's 1,000-grapheme authoring limit.
  // Keep the string type and 10,000-byte bound, and preserve the complete alt.
  delete alt.maxGraphemes;
  agent.lex.remove(id);
  agent.lex.add(video);
}
