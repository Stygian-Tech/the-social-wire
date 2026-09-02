export function shouldShowEditorialFeedLoading(
  storyCount: number,
  ...loadingStates: boolean[]
): boolean {
  return storyCount === 0 && loadingStates.some(Boolean);
}
