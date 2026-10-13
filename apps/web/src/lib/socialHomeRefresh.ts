export const SOCIAL_HOME_REFRESH_EVENT = "social-wire:refresh-social-home";

export function requestSocialHomeRefresh(): void {
  window.dispatchEvent(new window.Event(SOCIAL_HOME_REFRESH_EVENT));
}
