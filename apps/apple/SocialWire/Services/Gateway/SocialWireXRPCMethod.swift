enum SocialWireXRPCMethod {
    private static let prefix = "/xrpc/"

    static let getPreferences = prefix + "app.thesocialwire.sync.getPreferences"
    static let getSidebar = prefix + "app.thesocialwire.publication.getSidebar"
    static let refreshSidebar = prefix + "app.thesocialwire.publication.refreshSidebar"
    static let resolvePublication = prefix + "app.thesocialwire.publication.resolvePublication"
    static let getFeed = prefix + "app.thesocialwire.appview.getFeed"
    static let listEntries = prefix + "app.thesocialwire.appview.listEntries"
    static let getEntry = prefix + "app.thesocialwire.appview.getEntry"
    static let getUnreadCounts = prefix + "app.thesocialwire.appview.getUnreadCounts"
    static let putReadMark = prefix + "app.thesocialwire.appview.putReadMark"
    static let deleteReadMark = prefix + "app.thesocialwire.appview.deleteReadMark"
    static let markAllRead = prefix + "app.thesocialwire.appview.markAllRead"
    static let enrollSources = prefix + "app.thesocialwire.appview.enrollSources"
    static let purgeViewerData = prefix + "app.thesocialwire.appview.purgeViewerData"
}
