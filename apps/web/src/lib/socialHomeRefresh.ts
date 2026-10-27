export const SOCIAL_HOME_REFRESH_EVENT = "social-wire:refresh-social-home";

let pending = false;

export function requestSocialHomeRefresh(): void {
  pending = true;
  window.dispatchEvent(new window.Event(SOCIAL_HOME_REFRESH_EVENT));
}

/** Keep Home clicks until the destination timeline mounts after navigation. */
export function consumeSocialHomeRefresh(): boolean {
  const requested = pending;
  pending = false;
  return requested;
}
