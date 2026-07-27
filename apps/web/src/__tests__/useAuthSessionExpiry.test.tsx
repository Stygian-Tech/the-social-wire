import { act, cleanup, render, screen } from "@testing-library/react";
import { afterEach, expect, it } from "bun:test";

import { AuthProvider, useAuth } from "@/hooks/useAuth";
import { invalidateOAuthSession } from "@/lib/auth";

const originalDummyData = process.env.NEXT_PUBLIC_USE_DUMMY_DATA;

function AuthStateProbe() {
  const { session } = useAuth();
  return <p>{session ? `signed-in:${session.did}` : "signed-out"}</p>;
}

afterEach(() => {
  cleanup();
  if (originalDummyData === undefined) {
    delete process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
  } else {
    process.env.NEXT_PUBLIC_USE_DUMMY_DATA = originalDummyData;
  }
});

it("clears provider auth state when the OAuth session expires", async () => {
  process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "true";
  render(
    <AuthProvider>
      <AuthStateProbe />
    </AuthProvider>,
  );

  expect(screen.getByText(/^signed-in:/)).toBeTruthy();

  await act(async () => {
    invalidateOAuthSession("did:plc:socialwire-dummy-viewer", new Error("expired"));
  });

  expect(screen.getByText("signed-out")).toBeTruthy();
});
