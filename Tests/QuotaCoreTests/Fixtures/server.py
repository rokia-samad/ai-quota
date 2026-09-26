#!/usr/bin/python3
import json, sys, time
mode = sys.argv[0].split('/')[-1]
initialized = False
for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method == 'initialize':
        if mode == 'silent':
            time.sleep(5)
            continue
        time.sleep(.05)
        response = {}
    elif method == 'initialized':
        initialized = True
        continue
    elif method == 'account/rateLimits/read':
        if mode == 'error':
            print(json.dumps({'id':message['id'],'error':{'code':-32001,'message':'secret-like upstream detail'}}),flush=True)
            continue
        response = {'rateLimits':{'primary':{'usedPercent':0,'windowDurationMins':300}}} if initialized else None
        if mode == 'invalid': response = []
        if mode == 'notification':
            print(json.dumps({'method':'account/rateLimits/updated','params':response}),flush=True)
    else:
        continue
    # Exercise split JSONL frames too.
    output = json.dumps({'id':message['id'],'result':response}) + '\n'
    sys.stdout.write(output[:8]);sys.stdout.flush();time.sleep(.01)
    sys.stdout.write(output[8:]);sys.stdout.flush()
