import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

import {
  CircleStoryActionsStateProvider,
  useCircleStoryActions,
} from "@/components/Circle/CircleStoryActionsContext";

afterEach(cleanup);

function StoryActionsProbe() {
  const actions = useCircleStoryActions();
  if (!actions) return null;
  const hidden = actions.isHidden("story-1");
  return hidden ? (
    <button type="button" onClick={() => actions.undo("story-1")}>
      Undo
    </button>
  ) : (
    <button type="button" onClick={() => actions.hide("story-1")}>
      Hide
    </button>
  );
}

describe("CircleStoryActionsStateProvider", () => {
  it("hides immediately and sends an undo before refreshing", async () => {
    const writes: Array<{ storyId: string; hidden: boolean }> = [];
    const setHidden = mock(async (input: { storyId: string; hidden: boolean }) => {
      writes.push(input);
      return input;
    });
    const refresh = mock(async () => undefined);
    render(
      <CircleStoryActionsStateProvider
        setHidden={setHidden}
        refresh={refresh}
      >
        <StoryActionsProbe />
      </CircleStoryActionsStateProvider>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Hide" }));
    expect(screen.getByRole("button", { name: "Undo" })).toBeDefined();
    expect(writes[0]).toEqual({ storyId: "story-1", hidden: true });

    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    expect(screen.getByRole("button", { name: "Hide" })).toBeDefined();
    await waitFor(() => expect(writes).toHaveLength(2));
    expect(writes[1]).toEqual({ storyId: "story-1", hidden: false });
    await waitFor(() => expect(refresh).toHaveBeenCalledTimes(1));
  });
});
