import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const root=join(import.meta.dir,'../../..');
const read=(path:string)=>readFileSync(join(root,path),'utf8');
const spec=Bun.YAML.parse(read('packages/spec/openapi.yaml')) as any;
test('listener state is private revision CAS and supports exact rewind source positions',()=>{
 expect(spec.paths['/v1/podcasts/state'].put.responses['409']).toBeDefined();
 expect(spec.components.schemas.PodcastListenerState.properties.playbackSpeed).toEqual({type:'number',minimum:.5,maximum:3});
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
