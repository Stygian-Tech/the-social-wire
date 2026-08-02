import { afterEach, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import React, { useState } from "react";

const MockInput = React.forwardRef<
  HTMLInputElement,
  React.InputHTMLAttributes<HTMLInputElement>
>((props, ref) => <input ref={ref} {...props} />);
MockInput.displayName = "MockInput";

afterEach(cleanup);

mock.module("@/hooks/useLoginHandleSuggestions", () => ({
  useLoginHandleSuggestions: () => ({
    data: [
      {
        did: "did:plc:alice",
        handle: "alice.bsky.social",
        displayName: "Alice",
      },
      {
        did: "did:plc:alicia",
        handle: "alicia.example",
        displayName: "Alicia",
      },
    ],
    isFetching: false,
  }),
}));

mock.module("@/components/ui/input", () => ({
  Input: MockInput,
}));

mock.module("@/components/shared/Avatar", () => ({
  Avatar: ({ alt }: { alt: string }) => <span>{alt}</span>,
}));

it("supports keyboard typeahead selection and can reopen", async () => {
  const { LoginHandleTypeahead } = await import(
    "@/components/LoginHandleTypeahead"
  );

  function Harness() {
    const [value, setValue] = useState("ali");
    return (
      <LoginHandleTypeahead value={value} onValueChange={setValue} />
    );
  }

  render(<Harness />);
  const input = screen.getByRole("combobox");

  fireEvent.focus(input);
  expect(screen.getByRole("listbox")).toBeDefined();

  fireEvent.keyDown(input, { key: "ArrowDown" });
  fireEvent.keyDown(input, { key: "Enter" });
  expect((input as HTMLInputElement).value).toBe("alice.bsky.social");
  expect(screen.queryByRole("listbox")).toBeNull();

  fireEvent.focus(input);
  expect(screen.getByRole("listbox")).toBeDefined();
});

it("reports the selected actor while keeping the handle visible", async () => {
  const { ActorTypeaheadInput } = await import(
    "@/components/ActorTypeaheadInput"
  );
  const selected = mock(() => {});

  function Harness() {
    const [value, setValue] = useState("ali");
    return (
      <ActorTypeaheadInput
        id="publication"
        value={value}
        onValueChange={setValue}
        onSuggestionSelect={selected}
      />
    );
  }

  render(<Harness />);
  const input = screen.getByRole("combobox");
  fireEvent.focus(input);
  fireEvent.click(screen.getByRole("option", { name: /Alice/i }));

  expect((input as HTMLInputElement).value).toBe("alice.bsky.social");
  expect(selected).toHaveBeenCalledWith(
    expect.objectContaining({ did: "did:plc:alice" })
  );
});
