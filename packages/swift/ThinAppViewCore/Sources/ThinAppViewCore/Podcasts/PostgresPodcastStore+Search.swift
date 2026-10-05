import Foundation
import PostgresNIO

extension PostgresPodcastStore {
  /// Bound decrypted work and advance over nonmatches without a plaintext private search index.
  public func search(viewer: String, request: PodcastSearchRequest) async throws -> PodcastSearchResponse {
    try request.validate()
    let binding = try PodcastSearch.binding(viewer: viewer, request: request)
    let cursor = try PodcastSearchCursor.decode(request.cursor, binding: binding)
    let entity = cursor?.entity ?? -1
    let afterID = cursor?.id ?? ""
    let kind = request.kind ?? "all"
    let showID = request.showId
    let snapshot = try await state(viewer: viewer)
    let nativeShows = snapshot.state.manualLinks.map(\.protocolShowId)
    let rssShows = snapshot.state.manualLinks.map(\.rssShowId)
    let hidden = Set(nativeShows)
    let rows = try await pool.query("""
      WITH links AS (
        SELECT DISTINCT ON (native_show_id) native_show_id,rss_show_id FROM unnest(\(nativeShows)::text[],\(rssShows)::text[]) WITH ORDINALITY AS mapping(native_show_id,rss_show_id,ordinal)
        WHERE EXISTS (SELECT 1 FROM podcast_subscriptions s WHERE s.viewer_did=\(viewer) AND s.show_id=rss_show_id)
        ORDER BY native_show_id,ordinal
      ), catalog AS (
        SELECT 0 AS entity,s.id,s.id AS show_id,s.show_json::text AS payload,false AS is_private
        FROM podcast_shows s JOIN podcast_subscriptions v ON v.show_id=s.id WHERE v.viewer_did=\(viewer)
        UNION ALL SELECT 0,id,id,show_data,true FROM podcast_private_shows WHERE viewer_did=\(viewer) AND \(privateStorage != nil)
        UNION ALL SELECT 1,e.id,COALESCE(l.rss_show_id,e.show_id),e.episode_json::text,false
        FROM podcast_episodes e JOIN podcast_subscriptions v ON v.show_id=e.show_id
        LEFT JOIN links l ON l.native_show_id=e.show_id
        WHERE v.viewer_did=\(viewer) AND NOT EXISTS (
          SELECT 1 FROM podcast_episodes rss WHERE rss.show_id=l.rss_show_id AND rss.guid=e.guid AND e.guid IS NOT NULL
        )
        UNION ALL SELECT 1,id,show_id,episode_data,true FROM podcast_private_episodes WHERE viewer_did=\(viewer) AND \(privateStorage != nil)
      ) SELECT entity,id,payload,is_private,show_id FROM catalog
      WHERE (\(kind)='all' OR (\(kind)='shows' AND entity=0) OR (\(kind)='episodes' AND entity=1))
      AND (\(showID)::text IS NULL OR show_id=\(showID))
      AND (entity,id)>(\(entity),\(afterID)) ORDER BY entity,id LIMIT 501
      """, logger: logger)
    let limit = request.limit ?? 20
    var response = PodcastSearchResponse()
    var scanned = 0
    var last: PodcastSearchCursor?
    for try await row in rows {
      if scanned >= 500 || response.shows.count + response.episodes.count >= limit {
        response.hasMore = true
        break
      }
      let (entity, id, payload, isPrivate, logicalShowID) = try row.decode((Int, String, String, Bool, String).self)
      scanned += 1
      last = PodcastSearchCursor(binding: binding, entity: entity, id: id)
      let raw = try isPrivate ? requirePrivateStorage().open(payload, viewer: viewer, entity: entity == 0 ? "show" : "episode", id: id) : payload
      if entity == 0 {
        let show = try decode(raw, PodcastShow.self)
        let visible = isPrivate ? PodcastPrivateCatalog.visible(show) : show
        if !hidden.contains(id), PodcastSearch.matches(request.query, title: visible.title, description: visible.description, hosts: visible.hosts) {
          response.shows.append(visible)
        }
      } else {
        let episode = try decode(raw, PodcastEpisode.self)
        var visible = isPrivate ? PodcastPrivateCatalog.visible(episode) : episode
        visible.showId = logicalShowID
        visible.chapterSourceUrl = nil
        if PodcastSearch.matches(request.query, title: visible.title, description: visible.description) {
          response.episodes.append(visible)
        }
      }
    }
    if response.hasMore { response.cursor = try last?.encoded() }
    return response
  }
}
