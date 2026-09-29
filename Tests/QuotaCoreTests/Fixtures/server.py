#!/usr/bin/python3
import json, os, sys, time
mode = sys.argv[0].split('/')[-1]
initialized = False
for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method == 'initialize':
        if mode == 'silent':
            time.sleep(5)
            continue
        if mode == 'closed-stdin':
            # Stop reading before answering: every later client write hits a broken pipe.
            os.close(0)
            print(json.dumps({'id':message['id'],'result':{}}),flush=True)
            time.sleep(3)
            break
        time.sleep(.05)
        response = {}
    elif method == 'initialized':
        initialized = True
        continue
    elif method == 'account/rateLimits/read':
        if mode == 'server-request':
            # Server-initiated request reusing the client's id, which must not be taken as the response.
            print(json.dumps({'id':message['id'],'method':'item/tool/requestUserInput','params':{}}),flush=True)
            reply = json.loads(sys.stdin.readline())
            if reply.get('id') != message['id'] or reply.get('error', {}).get('code') != -32601:
                print(json.dumps({'id':message['id'],'error':{'code':-32099}}),flush=True)
                continue
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
