/// The app's layout, derived only from the scene's horizontal size class and width —
/// never from device idiom or orientation — so iPhone, both iPhone Duo displays,
/// iPad multitasking sizes, and Stage Manager windows all share one code path.
public enum LayoutTier: String, Comparable, Codable, Sendable {
    /// Bottom tab bar with one navigation stack per tab (iPhone, Duo outer display, narrow iPad windows).
    case compact
    /// Sidebar-adaptable tabs with list and detail columns (Duo inner display, iPad portrait, half-screen iPad).
    case regular
    /// Room for sidebar, list, and detail together, or deck columns (iPad landscape and large windows).
    case wide

    /// Minimum width, in points, at which a regular-width scene becomes `.wide`.
    public static let wideMinimumWidth: Double = 900

    public init(isHorizontallyRegular: Bool, width: Double) {
        if !isHorizontallyRegular {
            self = .compact
        } else if width >= Self.wideMinimumWidth {
            self = .wide
        } else {
            self = .regular
        }
    }

    /// Whether list and detail are shown side by side.
    public var showsSplitColumns: Bool { self != .compact }

    /// Whether adaptive tabs should default to their sidebar representation.
    public var prefersSidebarTabs: Bool { self != .compact }

    public static func < (lhs: LayoutTier, rhs: LayoutTier) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Ordering rank. Stated explicitly rather than looked up in a table, so comparing tiers
    /// allocates nothing and can't trap.
    private var rank: Int {
        switch self {
        case .compact: 0
        case .regular: 1
        case .wide: 2
        }
    }
}
