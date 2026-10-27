#if os(iOS)
import Navigation

/// A tab paired with the stack driving it. `Identifiable` by tab, so iterating a scene's tabs
/// gives each one a stable identity.
struct TabStack: Identifiable {
    let tab: AppTab
    let stack: RouteStack

    var id: AppTab { tab }
}

#endif
