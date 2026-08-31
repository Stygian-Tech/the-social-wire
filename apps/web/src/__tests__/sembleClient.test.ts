import { describe, expect, it } from "bun:test";

import {
  normalizeSembleCollectionPage,
  normalizeSembleCollectionsPage,
  normalizeSembleConnectionsPage,
} from "@/lib/sembleClient";

describe("Semble normalized reads", () => {
  it("normalizes owned collection summaries", () => {
    expect(
      normalizeSembleCollectionsPage({
        collections: [
          {
            uri: "at://did:plc:viewer/network.cosmik.collection/one",
            name: "Read This",
            accessType: "OPEN",
            cardCount: 3,
          },
          { name: "missing uri" },
        ],
        cursor: "next",
      }),
    ).toEqual({
      collections: [
        {
          uri: "at://did:plc:viewer/network.cosmik.collection/one",
          name: "Read This",
          accessType: "OPEN",
          cardCount: 3,
        },
      ],
      cursor: "next",
    });
  });

  it("retains partially linked items instead of dropping them", () => {
    const page = normalizeSembleCollectionPage({
      collection: {
        uri: "at://did:plc:viewer/network.cosmik.collection/one",
        name: "Read This",
        cardCount: 1,
      },
      items: [
        {
          id: "item-1",
          cardUri: "at://did:plc:author/network.cosmik.card/card",
          cardType: "URL",
          url: "https://example.com",
          membership: null,
          contributor: { did: "did:plc:author" },
          note: {
            uri: null,
            text: "Projected note",
            authorDid: "did:plc:author",
            editable: false,
          },
          unlinkAvailable: false,
        },
      ],
      membershipComplete: false,
      recordLinksComplete: false,
    });
    expect(page.items).toHaveLength(1);
    expect(page.items[0]?.membership).toBeUndefined();
    expect(page.items[0]?.note?.text).toBe("Projected note");
    expect(page.recordLinksComplete).toBe(false);
    expect(page.items[0]?.unlinkAvailable).toBe(false);
  });

  it("retains projected connections whose record URI is not ready", () => {
    const page = normalizeSembleConnectionsPage({
      connections: [
        {
          uri: null,
          source: "https://example.com/source",
          target: "https://example.com/target",
          connectionType: "RELATED",
          authorDid: "did:plc:viewer",
          editable: false,
        },
      ],
      recordLinksComplete: false,
    });
    expect(page.connections).toHaveLength(1);
    expect(page.connections[0]?.uri).toBeUndefined();
    expect(page.recordLinksComplete).toBe(false);
  });
});
