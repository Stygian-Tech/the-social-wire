const XRPC_PREFIX = "/xrpc/";

export const socialWireXrpc = {
  getPreferences: `${XRPC_PREFIX}app.thesocialwire.sync.getPreferences`,
  getSidebar: `${XRPC_PREFIX}app.thesocialwire.publication.getSidebar`,
  refreshSidebar: `${XRPC_PREFIX}app.thesocialwire.publication.refreshSidebar`,
  resolvePublication: `${XRPC_PREFIX}app.thesocialwire.publication.resolvePublication`,
  getFeed: `${XRPC_PREFIX}app.thesocialwire.appview.getFeed`,
  listEntries: `${XRPC_PREFIX}app.thesocialwire.appview.listEntries`,
  getEntry: `${XRPC_PREFIX}app.thesocialwire.appview.getEntry`,
  getUnreadCounts: `${XRPC_PREFIX}app.thesocialwire.appview.getUnreadCounts`,
  putReadMark: `${XRPC_PREFIX}app.thesocialwire.appview.putReadMark`,
  deleteReadMark: `${XRPC_PREFIX}app.thesocialwire.appview.deleteReadMark`,
  enrollSources: `${XRPC_PREFIX}app.thesocialwire.appview.enrollSources`,
  purgeViewerData: `${XRPC_PREFIX}app.thesocialwire.appview.purgeViewerData`,
  markAllRead: `${XRPC_PREFIX}app.thesocialwire.appview.markAllRead`,
} as const;
