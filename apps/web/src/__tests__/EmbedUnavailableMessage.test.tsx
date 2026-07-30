import { expect, it } from "bun:test";
import { render, screen } from "@testing-library/react";

import { EmbedUnavailableMessage } from "@/components/EntryDetail/EmbedUnavailableMessage";

it("keeps the embed message and action in one compact row", () => {
  const { rerender } = render(
    <EmbedUnavailableMessage
      href="https://example.com/article"
      message="This site blocks embedding."
      linkLabel="Open"
      fallbackContent={<article>Saved content</article>}
    />
  );

  const message = screen.getByText("This site blocks embedding.");
  const link = screen.getByRole("link", { name: "Open" });

  expect(message.parentElement).toBe(link.parentElement);
  expect(message.parentElement?.classList.contains("flex")).toBe(true);
  expect(message.parentElement?.classList.contains("flex-wrap")).toBe(true);
  expect(link.classList.contains("mt-3")).toBe(false);

  rerender(
    <EmbedUnavailableMessage
      href="https://example.com/article"
      message="This site blocks embedding."
      linkLabel="Open"
    />
  );

  const centeredMessage = screen.getByText("This site blocks embedding.");
  const centeredLink = screen.getByRole("link", { name: "Open" });

  expect(centeredMessage.parentElement).toBe(centeredLink.parentElement);
  expect(centeredMessage.parentElement?.classList.contains("justify-center")).toBe(true);
});
