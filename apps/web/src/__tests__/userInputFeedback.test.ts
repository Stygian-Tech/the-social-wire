import { describe, expect, it } from "bun:test";

import {
  fetchUserInputBoardReference,
  requireUserInputFeedbackScopes,
  USER_INPUT_BOARD_API_URL,
  USER_INPUT_BOARD_URI,
  USER_INPUT_REAUTH_MESSAGE,
  userInputDiscussionUrl,
} from "@/lib/userInputFeedback";

describe("UserInput feedback", () => {
  it("loads and validates the configured board reference", async () => {
    const calls: Array<[string, RequestInit | undefined]> = [];
    const fetcher = async (input: string, init?: RequestInit) => {
      calls.push([input, init]);
      return Response.json({
        board: {
          uri: USER_INPUT_BOARD_URI,
          cid: "bafyreifeedback",
          value: {
            tags: [
              { label: "Bug", value: "bug" },
              { label: "Feature", value: "feature" },
              { label: 42, value: "invalid" },
            ],
          },
        },
      });
    };

    await expect(fetchUserInputBoardReference(fetcher)).resolves.toEqual({
      uri: USER_INPUT_BOARD_URI,
      cid: "bafyreifeedback",
      tags: [
        { label: "Bug", value: "bug" },
        { label: "Feature", value: "feature" },
      ],
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]?.[0]).toBe(USER_INPUT_BOARD_API_URL);
    expect(calls[0]?.[1]?.cache).toBe("no-store");
  });

  it("rejects a response for a different board", async () => {
    const fetcher = async () =>
      Response.json({
        board: {
          uri: "at://did:plc:other/app.userinput.space/other",
          cid: "bafyreifeedback",
        },
      });

    await expect(fetchUserInputBoardReference(fetcher)).rejects.toThrow(
      "invalid response"
    );
  });

  it("accepts the UserInput permission set and legacy granular permissions", async () => {
    const permitted = {
      getTokenInfo: async () => ({
        scope: "atproto include:app.userinput.authFull",
      }),
    };
    const granularPermissions = {
      getTokenInfo: async () => ({
        scope:
          "atproto repo:app.userinput.discussion?action=create repo:app.userinput.upvote?action=create&action=update",
      }),
    };
    const staleSession = {
      getTokenInfo: async () => ({ scope: "atproto" }),
    };

    await expect(
      requireUserInputFeedbackScopes(permitted as never)
    ).resolves.toBeUndefined();
    await expect(
      requireUserInputFeedbackScopes(granularPermissions as never)
    ).resolves.toBeUndefined();
    await expect(
      requireUserInputFeedbackScopes(staleSession as never)
    ).rejects.toThrow(USER_INPUT_REAUTH_MESSAGE);
  });

  it("builds the public discussion URL from an AT URI", () => {
    expect(
      userInputDiscussionUrl(
        "at://did:plc:viewer/app.userinput.discussion/3testfeedback"
      )
    ).toBe(
      "https://userinput.app/d/did%3Aplc%3Aviewer/3testfeedback?lang=en"
    );
    expect(userInputDiscussionUrl("not-an-at-uri")).toBeNull();
  });
});
