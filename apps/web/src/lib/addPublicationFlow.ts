import type { ResolveAddPublicationPayload } from "@/lib/publicationProjectionClient";

export type ResolvedPublicationSearch = {
  input: string;
  publication: ResolveAddPublicationPayload;
};

export type AddPublicationSubmitAction =
  | { kind: "resolve"; input: string }
  | { kind: "subscribe"; input: string; publication: ResolveAddPublicationPayload };

export function addPublicationSubmitAction(args: {
  input: string;
  resolved: ResolvedPublicationSearch | null;
}): AddPublicationSubmitAction {
  const input = args.input.trim();
  if (args.resolved?.input === input) {
    return {
      kind: "subscribe",
      input,
      publication: args.resolved.publication,
    };
  }
  return { kind: "resolve", input };
}
