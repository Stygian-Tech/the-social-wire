import type { WireEditionPage } from "@/lib/wireEditionClient";
import type { WireItem, WireSource } from "@/lib/wireFeedClient";

const publications: WireSource[] = [
  { name: "The Standard", domain: "standard.example", publicationKey: "standard", homepageUrl: "https://standard.example", iconUrl: "/mock-reader/thumbnail-violet.svg" },
  { name: "Civic Signal", domain: "civic.example", publicationKey: "civic", homepageUrl: "https://civic.example", iconUrl: "/mock-reader/thumbnail-coral.svg" },
  { name: "Interface Notes", domain: "interface.example", publicationKey: "interface", homepageUrl: "https://interface.example", iconUrl: "/mock-reader/thumbnail-blue.svg" },
  { name: "Research Desk", domain: "research.example", publicationKey: "research", homepageUrl: "https://research.example", iconUrl: "/mock-reader/thumbnail-violet.svg" },
  { name: "Newsroom Index", domain: "newsroom.example", publicationKey: "newsroom", homepageUrl: "https://newsroom.example", iconUrl: "/mock-reader/thumbnail-coral.svg" },
  { name: "Standards Watch", domain: "standards.example", publicationKey: "standards", homepageUrl: "https://standards.example", iconUrl: "/mock-reader/thumbnail-blue.svg" },
];

const titles = [
  "Portable identity moves from protocol debate to newsroom reality",
  "Public-interest technology groups coordinate a new response",
  "The social web finds a clearer path through a week of changes",
  "A local newsroom turns community notes into lasting coverage",
  "What editors learned from a year of portable publishing",
  "New reader habits are changing the shape of the daily edition",
  "Open standards give independent publishers more room to grow",
  "The interface decisions that made a complex story understandable",
  "Researchers trace how one story crossed distinct communities",
  "A developing policy shift draws attention across the network",
  "Newsrooms prepare for the next phase of decentralized media",
  "Why this emerging story is moving faster than expected",
  "Communities far apart are asking the same urgent question",
  "Independent writers add context missing from the first reports",
  "A shared set of facts begins to emerge across the social web",
  "The conversation expands beyond its original audience",
  "An overlooked investigation returns with new evidence",
  "A months-old report becomes newly relevant this morning",
  "Readers resurface a durable guide to a changing platform",
  "The archive adds important context to today’s headline",
  "Smaller publications connect the details behind a broad trend",
  "The latest dispatches worth following around the network",
  "A practical guide to the week’s most consequential changes",
  "More reporting and analysis from across the social web",
];

function story(index: number): WireItem {
  const source = {
    ...publications[index % publications.length],
    author: ["Maya Chen", "Jon Bell", "Imani Reed", "Alex Rivera"][index % 4],
  };
  const reason = index < 13
    ? index % 2 === 0 ? "breaking_story" : "widely_discussed"
    : index < 17 ? "shared_across_communities"
      : index < 21 ? "resurfacing" : "fresh_publication";
  const url = `/mock-reader/article.html?${new URLSearchParams({
    title: titles[index],
    summary: "Reporting, analysis, and public conversation add new context to an important story moving across the social web.",
  }).toString()}`;
  return {
    itemId: `wire-preview-${index + 1}`,
    canonicalUrl: url,
    title: titles[index],
    summary: "Reporting, analysis, and public conversation add new context to an important story moving across the social web.",
    publishedAt: new Date(Date.UTC(2026, 7, 21, 18 - Math.floor(index / 3), index % 60)).toISOString(),
    thumbnailUrl: `/mock-reader/thumbnail-${["violet", "coral", "blue"][index % 3]}.svg`,
    source,
    reasons: [reason],
    provenance: index % 3 === 0 ? ["standard_site"] : ["direct_share"],
  };
}

export function dummyWireEdition(): WireEditionPage {
  const stories = titles.map((_, index) => story(index));
  return {
    editionVersion: "wire-edition-v2",
    generationId: "00000000-0000-4000-8000-000000000001",
    generatedAt: "2026-08-21T22:00:00.000Z",
    language: "en",
    source: "ranked",
    degraded: false,
    stories,
    topStoryIds: [
      "wire-preview-1",
      "wire-preview-2",
      "wire-preview-3",
      "wire-preview-4",
    ],
    publicationSpotlights: publications.slice(0, 3).map((publication, index) => ({
      id: publication.publicationKey ?? publication.domain,
      publication,
      storyIds: [`wire-preview-${index * 2 + 4}`, `wire-preview-${index * 2 + 5}`],
    })),
    storyRails: [
      { id: "breaking-developing", title: "Breaking & Developing", storyIds: ["wire-preview-10", "wire-preview-11", "wire-preview-12", "wire-preview-13"] },
      { id: "across-communities", title: "Across Communities", storyIds: ["wire-preview-14", "wire-preview-15", "wire-preview-16", "wire-preview-17"] },
      { id: "resurfacing", title: "Resurfacing", storyIds: ["wire-preview-18", "wire-preview-19", "wire-preview-20", "wire-preview-21"] },
      { id: "more-across-the-social-web", title: "More Across the Social Web", storyIds: ["wire-preview-22", "wire-preview-23", "wire-preview-24"] },
    ],
    people: [
      ["did:plc:maya", "maya.news", "Maya Chen"],
      ["did:plc:jon", "jon.social", "Jon Bell"],
      ["did:plc:imani", "imani.media", "Imani Reed"],
      ["did:plc:alex", "alex.pub", "Alex Rivera"],
      ["did:plc:noor", "noor.world", "Noor Ahmed"],
      ["did:plc:sam", "sam.network", "Sam Okafor"],
    ].map(([did, handle, displayName], index) => ({
      did,
      handle,
      displayName,
      avatarUrl: `/mock-reader/thumbnail-${["violet", "coral", "blue"][index % 3]}.svg`,
      description: "Explicitly mentioned across several important stories this week.",
    })),
    trendingStoryIds: stories.slice(0, 10).map((item) => item.itemId),
  };
}
