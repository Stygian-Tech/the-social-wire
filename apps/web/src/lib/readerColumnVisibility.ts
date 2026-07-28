export function shouldShowArticleListColumn({
  isTabletPortrait,
  isOpenInTabletPortrait,
}: {
  isTabletPortrait: boolean;
  isOpenInTabletPortrait: boolean;
}): boolean {
  return !isTabletPortrait || isOpenInTabletPortrait;
}
