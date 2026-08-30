import { afterEach, describe, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";

import {
  CircleSharerStrip,
  publicCircleShareURL,
} from "@/components/Circle/CircleSharerStrip";
import type { CircleSharer } from "@/lib/circleFeedClient";

afterEach(cleanup);

const sharers: CircleSharer[] = Array.from({ length: 5 }, (_, index) => ({
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
  it("shows at most three public sharers plus overflow and relationship labels", () => {
    render(<CircleSharerStrip sharers={sharers} />);

    const links = screen.getAllByRole("link");
    expect(links).toHaveLength(3);
    expect(screen.getByText("+2")).toBeDefined();
    expect(screen.getByText("Following")).toBeDefined();
    expect(screen.getAllByText("One Hop")).toHaveLength(2);
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
