import { afterEach, describe, expect, it } from "bun:test";

import {
  dummyEntriesForAggregateFeed,
  dummyEntriesForPublication,
  dummyLatrGatewaySavedItemsResponse,
  dummyLatrSavesForState,
  dummyPublicationSidebarProjection,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";
import { isRssEntryId } from "@/lib/rssFeedCore";
import { mergedLatrSavesFromGatewayItems } from "@/lib/pdsClient";

const env = process.env as Record<string, string | undefined>;
const savedEnv = {
  NEXT_PUBLIC_APP_ENV: env.NEXT_PUBLIC_APP_ENV,
  APP_ENV: env.APP_ENV,
  NEXT_PUBLIC_USE_DUMMY_DATA: env.NEXT_PUBLIC_USE_DUMMY_DATA,
};

afterEach(() => {
  env.NEXT_PUBLIC_APP_ENV = savedEnv.NEXT_PUBLIC_APP_ENV;
  env.APP_ENV = savedEnv.APP_ENV;
  env.NEXT_PUBLIC_USE_DUMMY_DATA = savedEnv.NEXT_PUBLIC_USE_DUMMY_DATA;
});

describe("dummyReaderData", () => {
  it("is always enabled in the local app environment", () => {
    env.NEXT_PUBLIC_APP_ENV = "local";
    env.NEXT_PUBLIC_USE_DUMMY_DATA = "false";

    expect(isDummyReaderDataEnabled()).toBe(true);
  });

  it("can still be explicitly enabled outside the local environment", () => {
    env.NEXT_PUBLIC_APP_ENV = "dev";
    env.NEXT_PUBLIC_USE_DUMMY_DATA = "true";

    expect(isDummyReaderDataEnabled()).toBe(true);
  });

  it("builds aggregate feeds without an AppView session", () => {
    const subscribed = dummyEntriesForAggregateFeed({ kind: "subscribed" });
    const following = dummyEntriesForAggregateFeed({ kind: "following" });
    const product = dummyEntriesForAggregateFeed({
      kind: "folder",
      id: "product",
    });

    expect(subscribed.length).toBeGreaterThan(20);
    expect(following.length).toBeGreaterThan(10);
    expect(product.length).toBeGreaterThan(10);
    expect(subscribed.every((entry) => entry.publicationId)).toBe(true);
    expect(subscribed.every((entry) => entry.thumbnailUrl)).toBe(true);
  });

  it("includes RSS rows that exercise the local reader dialog", () => {
    const rssPublication =
      dummyPublicationSidebarProjection.followingTabPublications.find(
        (publication) => publication.authorDid === "did:web:skyreader.rss",
      );
    expect(rssPublication).toBeDefined();

    const entries = dummyEntriesForPublication(rssPublication!.publicationId);
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.every((entry) => isRssEntryId(entry.entryId))).toBe(true);
    expect(
      entries.every((entry) =>
        entry.originalUrl?.startsWith("/mock-reader/article.html"),
      ),
    ).toBe(true);
    expect(entries.some((entry) => !entry.thumbnailUrl)).toBe(true);
    expect(entries.some((entry) => !entry.summary)).toBe(true);
    expect(entries.some((entry) => (entry.title?.length ?? 0) > 80)).toBe(true);
  });

  it("provides local active and archived read-later rows", () => {
    expect(dummyLatrSavesForState("active")).toHaveLength(2);
    expect(dummyLatrSavesForState("archived")).toHaveLength(1);
  });

  it("round-trips samples through the LatrKit gateway response shape", () => {
    const rows = mergedLatrSavesFromGatewayItems(
      dummyLatrGatewaySavedItemsResponse().records,
    );

    expect(rows).toHaveLength(3);
    expect(rows[0]?.title).toBeTruthy();
    expect(rows[0]?.image).toStartWith("/mock-reader/");
    expect(rows[0]?.linkedWebUrl).toStartWith("/mock-reader/article.html");
  });
});
