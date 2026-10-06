#!/usr/bin/env python3
import argparse, json, random, subprocess
p=argparse.ArgumentParser();p.add_argument('--swift',required=True);p.add_argument('--go',required=True);args=p.parse_args()
r=random.Random(2049)
for case in range(35):
    items=[]
    for i in range(0 if case==0 else r.randrange(1,90)):
        item={'itemId':str(r.randrange(1,60)), 'canonicalUrl':f'https://example.com/{i}', 'title':f'Story {i}',
              'source':{'name':f'Publisher {i%9}', 'domain':f'publisher-{i%9}.example'},
              'reasons':r.sample(['breaking_story','widely_discussed','shared_across_communities','resurfacing','fresh_publication'],r.randrange(0,4)),
              'provenance':['direct_share']*12}
        if i%7==0:item['representativeUri']=f'at://did:plc:a/site.standard.document/{i}'
        if i%3==0:item['source']['publicationKey']=f' Publication {i%11} '
        items.append(item)
    accounts=[{'account':{'did':f'did:plc:{r.randrange(1,12)}'},'distinctStoryCount':r.randrange(0,12),
               'distinctSpeakerCount':r.randrange(0,12),'bestStoryRank':r.randrange(0,20)} for _ in range(30)]
    data=json.dumps({'items':items,'accounts':accounts,'asOf':'2026-10-05T12:00:00Z'}).encode()
    def run(binary):return json.loads(subprocess.run([binary],input=data,check=True,capture_output=True).stdout)
    a,b=run(args.swift),run(args.go)
    if a!=b:
        raise AssertionError(f'edition case {case} differs: Swift={json.dumps(a)} Go={json.dumps(b)}')
print('Swift/Go edition parity passed: 35 snapshots')
