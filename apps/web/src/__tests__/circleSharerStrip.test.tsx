import { afterEach, describe, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";

import {
  CircleSharerStrip,
  publicCircleShareURL,
} from "@/components/Circle/CircleSharerStrip";
import type { CircleSharer } from "@/lib/circleFeedClient";

afterEach(cleanup);

const sharers: CircleSharer[] = Array.from({ length: 7 }, (_, index) => ({
  identity: {
    did: `did:plc:person${index}`,
    handle: `person${index}.example`,
    displayName: `Person ${index}`,
  },
  relationship: index === 0 ? "direct" : "one_hop",
  action: "shared",
  sourceUri: `at://did:plc:person${index}/app.bsky.feed.post/post${index}`,
  timestamp: "2026-08-30T00:00:00Z",
}));

describe("CircleSharerStrip", () => {
  it("shows five linked avatars without visible names before adding overflow", () => {
    render(<CircleSharerStrip sharers={sharers.slice(0, 5)} totalCount={7} />);

    const links = screen.getAllByRole("link");
    expect(links).toHaveLength(5);
    expect(screen.getByText("+2")).toBeDefined();
    expect(screen.queryByText("Following")).toBeNull();
    for (let index = 0; index < 5; index += 1) {
      expect(screen.queryByText(`Person ${index}`)).toBeNull();
      expect(
        screen.getByRole("link", {
          name: new RegExp(`Open Person ${index}'s public share context`),
        }),
      ).toBeDefined();
    }
    expect(screen.getAllByText("+1")).toHaveLength(4);
    expect(links[0]?.getAttribute("href")).toBe(
      "https://bsky.app/profile/did%3Aplc%3Aperson0/post/post0",
    );
  });

  it("opens the exact public record for non-Bluesky AT Protocol shares", () => {
    expect(
      publicCircleShareURL({
        ...sharers[0]!,
        sourceUri: "at://did:plc:person0/at.margin.note/note0",
      }),
    ).toBe(
      "https://pdsls.dev/at://did:plc:person0/at.margin.note/note0",
    );
  });
});
