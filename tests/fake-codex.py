#!/usr/bin/env python3
import sys,json
for line in sys.stdin:
    request=json.loads(line)
    if request['method']=='initialize':
        print(json.dumps({'id':1,'result':{}}),flush=True)
    elif request['method']=='account/rateLimits/read':
        result={'id':2,'result':{'rateLimits':{'primary':{'usedPercent':17,'windowDurationMins':300},'secondary':{'usedPercent':52,'windowDurationMins':10080}}}}
        print(json.dumps({'method':'unrelated/notification'}),flush=True)
        print(json.dumps(result),flush=True)
