export type OperationsPaginationState = {
  route: string
  cursor?: string
  history: Array<string | undefined>
}

export function previousOperationsPage(
  state: OperationsPaginationState,
  routeKey: string,
): OperationsPaginationState {
  const history = state.route === routeKey ? state.history : []
  return { route: routeKey, cursor: history.at(-1), history: history.slice(0, -1) }
}

export function nextOperationsPage(
  routeKey: string,
  nextCursor: string,
  currentCursor: string | undefined,
  history: Array<string | undefined>,
): OperationsPaginationState {
  return { route: routeKey, cursor: nextCursor, history: [...history, currentCursor] }
}
