#!/usr/bin/env python3
"""Compare the actual Swift ranker and Go ranker on deterministic boundary cases."""
import argparse
import datetime as dt
import json
import math
import random
import subprocess

NOW = dt.datetime(2026, 10, 5, 12, tzinfo=dt.timezone.utc)

def candidate(index, **overrides):
    value = dict(canonicalKey=f'url:{index:04}', canonicalURL=f'https://source{index % 13}.example/{index}',
                 representativeURI=None, sourceDomain=f'source{index % 13}.example',
                 publicationID=f'pub:{index % 23}', authorKey=f'author:{index % 31}', topicKeys=[f'topic:{index % 9}'],
                 publishedAt=None, firstSeenAt=NOW.isoformat().replace('+00:00', 'Z'), lastSignalAt=None,
                 distinctActors1h=0, distinctActors24h=0, distinctActors7d=0,
                 signals1h=0, signals24h=0, signals7d=0, communities24h=0,
                 primaryCommunityKey=f'community:{index % 7}', recommendations24h=0,
                 positiveFeedback24h=0, negativeFeedback24h=0, shares1h=0, shares24h=5,
                 distinctLikes24h=0, likes1h=0, likes24h=0, distinctReposts24h=0, reposts1h=0,
                 reposts24h=0, sourceConfidence=.75, isStandardSite=False,
                 hasUsableOpenGraphMetadata=True, hasUsableThumbnail=True,
                 targetKind='external_article', commercialClass='normal', commercialScore=0)
    value.update(overrides)
    return value

def cases():
    yield []
    yield [candidate(0)]
    yield [candidate(i, shares24h=count, isStandardSite=standard,
                     firstSeenAt=(NOW-dt.timedelta(seconds=age)).isoformat().replace('+00:00','Z'))
           for i,(count,standard,age) in enumerate([(0,False,0),(1,True,259200),(1,True,259201),
             (3,False,0),(5,False,2592000),(5,False,2592001),(5,False,-1)])]
    yield [candidate(i, shares1h=3, shares24h=3,
                     firstSeenAt=(NOW-dt.timedelta(seconds=age)).isoformat().replace('+00:00','Z'))
           for i,age in enumerate([21599,21600,21601])]
    yield [candidate(i, sourceConfidence=confidence, targetKind=kind, commercialClass=commercial)
           for i,(confidence,kind,commercial) in enumerate([(.249,'external_article','normal'),
           (.25,'external_article','normal'),(.75,'social_post','normal'),(.75,'external_article','probable_ad'),
           (.75,'standard_site_document','limited')])]
    yield [candidate(i, sourceDomain='same.example', publicationID='same', authorKey='same',
                     topicKeys=['same','same'], primaryCommunityKey='same') for i in range(100)]
    randomizer = random.Random(79)
    for _ in range(24):
        values=[]
        for i in range(randomizer.randrange(1,250)):
            age=randomizer.choice([0,21600,21601,172800,259200,259201,2592000,2592001,randomizer.randrange(3000000)])
            values.append(candidate(i,
                firstSeenAt=(NOW-dt.timedelta(seconds=age)).isoformat().replace('+00:00','Z'),
                shares1h=randomizer.randrange(15),shares24h=randomizer.randrange(50),
                recommendations24h=randomizer.randrange(4),signals7d=randomizer.randrange(1000),
                positiveFeedback24h=randomizer.randrange(20),negativeFeedback24h=randomizer.randrange(20),
                communities24h=randomizer.randrange(9),isStandardSite=randomizer.choice([True,False,None]),
                hasUsableOpenGraphMetadata=randomizer.choice([True,False,None]),
                hasUsableThumbnail=randomizer.choice([True,False,None]),
                sourceConfidence=randomizer.choice([.1,.25,.5,.75,1]),
                commercialClass=randomizer.choice(['normal','limited','probable_ad']),
                commercialScore=randomizer.choice([0,3,5,6])))
        yield values

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--swift',required=True);p.add_argument('--go',required=True);args=p.parse_args()
    for number,values in enumerate(cases()):
        payload=json.dumps({'asOf':NOW.isoformat().replace('+00:00','Z'),'candidates':values}).encode()
        expected=json.loads(subprocess.run([args.swift],input=payload,capture_output=True,check=True).stdout)
        actual=json.loads(subprocess.run([args.go],input=payload,capture_output=True,check=True).stdout)
        assert expected['diagnostics']==actual['diagnostics'],(number,expected['diagnostics'],actual['diagnostics'])
        assert len(expected['items'])==len(actual['items']),number
        for left,right in zip(expected['items'],actual['items']):
            assert left['candidate']['canonicalKey']==right['candidate']['canonicalKey'],(number,left,right)
            assert left['reasonCodes']==right['reasonCodes'],(number,left,right)
            assert math.isclose(left['score'],right['score'],rel_tol=0,abs_tol=1e-12),(number,left,right)
    print(f'Wire ranking parity passed for {number+1} Swift/Go snapshots.')
