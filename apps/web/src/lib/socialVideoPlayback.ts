/** Load the streaming engine only when a video enters the viewport. */
export async function loadSocialVideoHls() {
  return (await import("hls.js")).default;
}
