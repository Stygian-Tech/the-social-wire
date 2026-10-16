import type { OAuthSession } from "@atproto/oauth-client-browser";

type MutationQueue = { active: boolean; generation: number; tail: Promise<void> };
const queues = new WeakMap<OAuthSession, MutationQueue>();
function queueFor(oauth: OAuthSession): MutationQueue {
  let queue = queues.get(oauth);
  if (!queue) { queue = { active: true, generation: 0, tail: Promise.resolve() }; queues.set(oauth, queue); }
  return queue;
}

// Reserve before authority lookup or a legacy request: a delayed 409 transition
// must not let an older bulk action overtake a newer single-entry action.
export function queueReadStateMutation<T>(oauth: OAuthSession, operation: (assertCurrent: () => void) => Promise<T>): Promise<T> {
  const queue = queueFor(oauth), generation = queue.generation;
  const assertCurrent = () => {
    if (!queue.active || generation !== queue.generation) throw new DOMException("Read-state session stopped", "AbortError");
  };
  try { assertCurrent(); } catch (error) { return Promise.reject(error); }
  const result = queue.tail.then(async () => { assertCurrent(); const value = await operation(assertCurrent); assertCurrent(); return value; });
  queue.tail = result.then(() => {}, () => {});
  return result;
}
export function stopReadStateMutations(oauth: OAuthSession): void {
  const queue = queueFor(oauth);
  queue.active = false; queue.generation++; queue.tail = Promise.resolve();
}
export function resumeReadStateMutations(oauth: OAuthSession): void { queueFor(oauth).active = true; }
