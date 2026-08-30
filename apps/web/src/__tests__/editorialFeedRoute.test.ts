import { describe, expect, it } from "bun:test";

import { editorialFeedForReadRoute } from "@/lib/editorialFeedRoute";

describe("editorialFeedForReadRoute", () => {
  it("recognizes The Wire and Your Circle as editorial feeds", () => {
    expect(editorialFeedForReadRoute("/read", "wire")).toBe("wire");
    expect(editorialFeedForReadRoute("/read", "circle")).toBe("circle");
  });

  it("keeps publication feeds on the read-state shell", () => {
    expect(editorialFeedForReadRoute("/read", "subscribed")).toBeNull();
    expect(editorialFeedForReadRoute("/read", "following")).toBeNull();
    expect(editorialFeedForReadRoute("/read/publication", "circle")).toBeNull();
  });
});
