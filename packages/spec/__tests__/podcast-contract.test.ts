import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const root=join(import.meta.dir,'../../..');
const read=(path:string)=>readFileSync(join(root,path),'utf8');
const spec=Bun.YAML.parse(read('packages/spec/openapi.yaml')) as any;
test('listener state is private revision CAS and supports exact rewind source positions',()=>{
 expect(spec.paths['/v1/podcasts/state'].put.responses['409']).toBeDefined();
 expect(spec.components.schemas.PodcastListenerState.properties.playbackSpeed).toEqual({type:'number',minimum:.75,maximum:2,multipleOf:.25});
 expect(spec.components.schemas.PodcastStateSnapshot.required).toEqual(['revision','state']);
 expect(read('database/migrations/20261005010000_podcast_listener.sql')).toContain('podcast_viewer_state');
 expect(read('packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/Podcasts/PostgresPodcastStore.swift')).toContain('revision=');
});
test('podcast media and private/public clips preserve HTTP ranges and server contracts',()=>{
 for(const path of ['/v1/podcasts/media','/v1/podcasts/assets','/v1/podcasts/public/assets']) {
  expect(spec.paths[path].get.responses['206']).toBeDefined();expect(spec.paths[path].get.responses['416']).toBeDefined();
 }
 expect(spec.paths['/v1/podcasts/clips/publish'].post).toBeDefined();expect(spec.paths['/v1/podcasts/clips'].delete).toBeDefined();
 expect(spec.components.schemas.PodcastTranscript.properties.cues.items.properties.startSeconds.type).toBe('number');
 for(const service of ['appview','gateway']) expect(read(`services/${service}/bruno/Podcasts/POST clips publish.bru`)).toContain('/v1/podcasts/clips/publish');
});
test('podcasts remain gated and isolated from article retention and public private history',()=>{
 expect(read('services/appview/Sources/AppView/AppViewServiceConfig.swift')).toContain('podcastsEnabled: Bool = false');
 const migration=read('database/migrations/20261005010000_podcast_listener.sql');
 expect(migration).not.toContain('expires_at');expect(migration).toContain('dedupe_key text UNIQUE NOT NULL');
 expect(read('packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/Podcasts/PodcastProtocolAdapter.swift')).toContain('org.atpodcasting.podcast');
 expect(read('packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/Podcasts/PodcastProtocolAdapter.swift')).toContain('place.pod.show');
 expect(read('packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/Podcasts/PodcastProtocolAdapter.swift')).toContain('live.voxport.podcast.series');
});

test('private RSS subscriptions are viewer-owned and excluded from public processing',()=>{
 for(const [path,method] of [['/v1/podcasts/private/resolve','post'],['/v1/podcasts/private/refresh','post'],['/v1/podcasts/private/subscriptions','delete']]) {
  expect(spec.paths[path][method].security).toEqual([{ATProtoOAuthDPoP:[]}]);
 }
 for(const service of ['appview','gateway']) for(const action of ['POST private resolve','POST private refresh','DELETE private subscriptions']) expect(read(`services/${service}/bruno/Podcasts/${action}.bru`)).toContain('/v1/podcasts/private/');
 const privateSchema=read('database/migrations/20261006010000_private_podcast_subscriptions.sql');
 expect(privateSchema).toContain('PRIMARY KEY(viewer_did,id)');
 expect(privateSchema).toContain('feed_data text NOT NULL');
 expect(privateSchema).toContain('episode_data text NOT NULL');
 expect(privateSchema).not.toContain('feed_url');
 expect(privateSchema).not.toContain('podcast_jobs');
 expect(privateSchema).not.toContain('podcast_aliases');
 expect(spec.components.schemas.PodcastShow.properties.visibility.enum).toEqual(['private']);
 expect(spec.components.schemas.PodcastEpisode.properties.visibility.enum).toEqual(['private']);
});

test('publisher chapter and host metadata use shared arrays and private artwork proxy',()=>{
 expect(spec.components.schemas.PodcastEpisode.properties.chapters.items.$ref).toBe('#/components/schemas/PodcastChapter');
 expect(spec.components.schemas.PodcastShow.properties.hosts.items.$ref).toBe('#/components/schemas/PodcastPerson');
 expect(spec.paths['/v1/podcasts/image'].get.security).toEqual([{ATProtoOAuthDPoP:[]}]);
 for(const service of ['appview','gateway']) expect(read(`services/${service}/bruno/Podcasts/GET image.bru`)).toContain('/v1/podcasts/image');
 expect(read('services/appview/Sources/AppView/Podcasts/PodcastRoutes.swift')).toContain('silence:v2:');
 expect(read('services/podcast-worker/.env.example')).toContain('PODCAST_BRIDGE_ENABLED=false');
});

test('library search protects viewer queries and uses bounded continuation pages',()=>{
 const search=spec.paths['/v1/podcasts/search'].post;
 expect(search.security).toEqual([{ATProtoOAuthDPoP:[]}]);
 expect(spec.paths['/v1/podcasts/search'].get).toBeUndefined();
 expect(spec.components.schemas.PodcastSearchRequest.properties.scope.enum).toEqual(['library']);
 expect(spec.components.schemas.PodcastSearchResponse.required).toEqual(['shows','episodes','hasMore']);
 for(const service of ['appview','gateway']) expect(read(`services/${service}/bruno/Podcasts/POST search.bru`)).toContain('/v1/podcasts/search');
 const store=read('packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/Podcasts/PostgresPodcastStore+Search.swift');
 expect(store).toContain('LIMIT 501');expect(store).toContain('scanned >= 500');
 expect(store).not.toContain('INSERT');expect(store).not.toContain('UPDATE');
});
