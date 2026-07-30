export class CursorSingleFlight {
  private active:
    | {
        token: symbol;
        feedKey: string;
        cursor: string;
        promise: Promise<unknown>;
      }
    | undefined;

  run(args: {
    feedKey: string;
    cursor: string;
    request: () => Promise<unknown>;
  }): Promise<unknown> {
    if (
      this.active?.feedKey === args.feedKey &&
      this.active.cursor === args.cursor
    ) {
      return this.active.promise;
    }

    const token = Symbol(args.cursor);
    const promise = Promise.resolve()
      .then(args.request)
      .finally(() => {
        if (this.active?.token === token) this.active = undefined;
      });
    this.active = {
      token,
      feedKey: args.feedKey,
      cursor: args.cursor,
      promise,
    };
    return promise;
  }

  reset(): void {
    this.active = undefined;
  }
}
