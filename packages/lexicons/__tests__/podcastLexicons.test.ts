import { expect, test } from 'bun:test';
import { Lexicons } from '@atproto/lexicon';
import clip from '../app/thesocialwire/podcast/clip.json';
import source from '../app/thesocialwire/podcast/source.json';

test('published clips use integer source timeline milliseconds and public asset references', () => {
 const lexicons=new Lexicons([clip as any,source as any]);
 const record={$type:clip.id,episodeId:'episode:abc',title:'Clip',startMillis:1234,endMillis:9900,audioUrl:'https://example.com/audio',videoUrl:'https://example.com/video',createdAt:'2026-10-05T00:00:00Z'};
 expect(()=>lexicons.assertValidRecord(clip.id,record)).not.toThrow();
 expect(()=>lexicons.assertValidRecord(clip.id,{...record,startMillis:1.5})).toThrow();
 expect(()=>lexicons.assertValidRecord(clip.id,{...record,startMillis:-1})).toThrow();
});
test('RSS mirror provenance contains feed identity and excludes listening history', () => {
 expect(source.defs.main.record.required).toEqual(['feedUrl','podcastGuid','showUri','bridgeDid','createdAt','updatedAt']);
 expect(source.defs.main.record.properties).not.toHaveProperty('progress');
 expect(clip.defs.main.record.properties).not.toHaveProperty('viewerDid');
});
