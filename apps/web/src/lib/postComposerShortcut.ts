import type { KeyboardEvent } from "react";

/** Submit through the enabled primary button so every composer keeps its existing guards. */
export function handlePostComposerShortcut(event: KeyboardEvent<HTMLFormElement>) {
  if (event.defaultPrevented || event.nativeEvent.isComposing || event.keyCode === 229 || event.key !== "Enter" || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey || !(event.target instanceof Node) || !event.currentTarget.contains(event.target)) return;
  event.preventDefault();
  if (event.repeat) return;
  const button = event.currentTarget.querySelector<HTMLButtonElement>('button[type="submit"]');
  if (button && !button.disabled) event.currentTarget.requestSubmit(button);
}
