/** Standard browser scheduler for the official CAR reader's cooperative yield. */
export function setImmediate(): Promise<void> { return new Promise(resolve => setTimeout(resolve, 0)); }
