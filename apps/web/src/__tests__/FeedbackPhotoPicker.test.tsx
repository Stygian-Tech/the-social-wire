import { afterEach, beforeAll, describe, expect, it } from "bun:test";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { useState } from "react";

import { FeedbackPhotoPicker } from "@/components/AppSidebar/FeedbackPhotoPicker";

afterEach(cleanup);

beforeAll(() => {
  Object.defineProperty(globalThis, "HTMLElement", {
    configurable: true,
    value: window.HTMLElement,
  });
});

function PhotoPickerHarness() {
  const [photos, setPhotos] = useState<File[]>([]);
  return (
    <FeedbackPhotoPicker photos={photos} onPhotosChange={setPhotos} />
  );
}

describe("FeedbackPhotoPicker", () => {
  it("accepts images, rejects other files, and caps the selection at four", () => {
    render(<PhotoPickerHarness />);
    const input = screen.getByLabelText("Add Photos") as HTMLInputElement;
    const files = [
      new File(["1"], "one.png", { type: "image/png" }),
      new File(["2"], "two.jpg", { type: "image/jpeg" }),
      new File(["3"], "three.webp", { type: "image/webp" }),
      new File(["4"], "four.gif", { type: "image/gif" }),
      new File(["5"], "five.png", { type: "image/png" }),
      new File(["no"], "notes.txt", { type: "text/plain" }),
    ];

    fireEvent.change(input, { target: { files } });

    expect(screen.getByText("4 of 4")).toBeDefined();
    expect(
      within(screen.getByRole("list", { name: "Attached Photos" })).getAllByRole(
        "listitem",
      ),
    ).toHaveLength(4);
    expect(screen.queryByText("five.png")).toBeNull();
    expect(screen.queryByText("notes.txt")).toBeNull();
  });

  it("allows an attached photo to be removed", () => {
    render(<PhotoPickerHarness />);
    const input = screen.getByLabelText("Add Photos") as HTMLInputElement;
    fireEvent.change(input, {
      target: {
        files: [new File(["1"], "screenshot.png", { type: "image/png" })],
      },
    });

    fireEvent.click(
      screen.getByRole("button", { name: "Remove screenshot.png" })
    );

    expect(screen.getByText("0 of 4")).toBeDefined();
    expect(screen.queryByText("screenshot.png")).toBeNull();
  });
});
