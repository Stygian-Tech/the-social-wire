import { AppBskyRichtextFacet, RichText, type ChatBskyConvoDefs } from "@atproto/api";
import type { ReactNode } from "react";
import Link from "next/link";
import { socialProfilePageHref, isSocialProfileActor } from "@/lib/socialProfileNavigation";
import { socialHttpsUrl } from "./socialUrls";

export function SocialChatRichText({ message }: { message: Pick<ChatBskyConvoDefs.MessageView, "text" | "facets"> }) {
  function links(text: string): ReactNode[] {
    const nodes: ReactNode[] = [];
    let end = 0;
    for (const match of text.matchAll(/https:\/\/[^\s<>"']+/g)) {
      const index = match.index!;
      const value = match[0].replace(/[.,!?;:]+$/, "");
      nodes.push(text.slice(end, index));
      const href = socialHttpsUrl(value);
      nodes.push(href ? <a key={index} href={href} target="_blank" rel="noopener noreferrer" className="text-primary underline hover:no-underline">{value}</a> : value);
      end = index + value.length;
    }
    nodes.push(text.slice(end));
    return nodes;
  }
  return <p className="whitespace-pre-wrap break-words text-sm leading-snug [overflow-wrap:anywhere]">{[...new RichText({ text: message.text, facets: message.facets }).segments()].map((segment, index) => {
    const feature = segment.facet?.features.find(value => AppBskyRichtextFacet.isLink(value) || AppBskyRichtextFacet.isMention(value));
    if (AppBskyRichtextFacet.isLink(feature)) {
      const href = socialHttpsUrl(feature.uri);
      return href ? <a key={index} href={href} target="_blank" rel="noopener noreferrer" className="text-primary underline hover:no-underline">{segment.text}</a> : <span key={index}>{segment.text}</span>;
    }
    if (AppBskyRichtextFacet.isMention(feature) && isSocialProfileActor(feature.did)) return <Link key={index} href={socialProfilePageHref(feature.did)} className="text-primary underline hover:no-underline">{segment.text}</Link>;
    return <span key={index}>{links(segment.text)}</span>;
  })}</p>;
}
