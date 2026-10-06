#!/usr/bin/env python3
import argparse, json, random, subprocess
p=argparse.ArgumentParser();p.add_argument('--swift',required=True);p.add_argument('--go',required=True);args=p.parse_args()
r=random.Random(640)
entities=[{'id':kind,'name':kind,'kind':kind,'competitionIDs':[],'aliases':[],'providerIDs':{},'active':True} for kind in ['sport','team','athlete','competition','classification']]
for case in range(45):
    finance,sports=[],[]
    for i in range(0 if case==0 else r.randrange(1,140)):
        item={'itemId':str(r.randrange(1,120)),'canonicalUrl':f'https://example.com/{r.randrange(1,130)}',
              'title':r.choice([f'Story {i}','The earnings announcement has further coverage','MÜNCHEN team wins a championship']),
              'source':{'name':'Publication','domain':f'publisher-{r.randrange(0,5)}.example'},'reasons':[],'provenance':[]}
        if i%3==0:item['publishedAt']=f'2026-10-05T{r.randrange(0,24):02}:00:00Z'
        base=round(r.random()*10,8)
        finance.append({'item':item,'analysis':{'eligible':r.random()>.1,'materiality':r.choice(['earnings','filing','merger','regulation','leadership','price-chatter','reporting']),
                         'associations':[{'instrumentID':r.choice(['a','b','c']),'confidence':1,'evidence':[],'prominence':0,'resolverVersion':'finance-resolver-v3.4'}],
                         'sectorIDs':[r.choice(['s','other'])]},'baseScore':base,'majorGlobal':r.random()>.7})
        version=r.choice(['sports-resolver-v14']*8+['old'])
        sports.append({'item':item,'analysis':{'resolverVersion':version,'eligible':r.random()>.1,'materiality':r.choice(['championship','record','transfer','injury','routine-chatter','reporting']),
                       'associations':[{'entityID':r.choice(['team','athlete','competition','classification']),'confidence':r.choice([1,.95,.8]),'evidence':[],'prominence':0,'resolverVersion':version}],
                       'sportIDs':[r.choice(['sport','other'])],'competitionIDs':['competition']},'baseScore':base,'majorGlobal':r.random()>.7})
    request={'finance':finance,'sports':sports,'instrumentIDs':r.sample(['a','b','c'],r.randrange(0,4)),
             'sectorIDs':r.sample(['s','other'],r.randrange(0,3)), 'followIDs':r.sample(['team','sport','competition'],r.randrange(0,4)),
             'muteIDs':r.sample(['team','sport','classification'],r.randrange(0,4)),'entities':entities,'reserveGlobal':bool(case%2)}
    data=json.dumps(request).encode()
    def run(binary):return json.loads(subprocess.run([binary],input=data,check=True,capture_output=True).stdout)
    a,b=run(args.swift),run(args.go)
    if a!=b:raise AssertionError(f'domain ranking case {case} differs: Swift={a} Go={b}')
print('Swift/Go Finance and Sports ranking parity passed: 45 snapshots')
