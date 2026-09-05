export class FeedResponseError extends Error {
  constructor(message: string, readonly code?: string, readonly status?: number) {
    super(message);
    this.name = "FeedResponseError";
  }
}

export function isExpiredFeedCursor(error: unknown): boolean {
  return error instanceof FeedResponseError && error.code === "CursorExpired";
}

export async function feedResponseError(response: Response, fallback: string): Promise<Error> {
  try {
    const body = (await response.json()) as { message?: string; error?: string };
    return new FeedResponseError(
      body.message?.trim() || `${fallback} (${response.status})`, body.error, response.status,
    );
  } catch {
    return new FeedResponseError(`${fallback} (${response.status})`, undefined, response.status);
  }
}

export async function refreshExpiredFeedCursor(
  error: unknown,
  refresh: () => Promise<unknown>,
): Promise<boolean> {
  if (!isExpiredFeedCursor(error)) return false;
  await refresh();
  return true;
}
