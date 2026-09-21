import subprocess,json,selectors,time,os
p=subprocess.Popen(['/Applications/ChatGPT.app/Contents/Resources/codex','app-server','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
def send(x):
 p.stdin.write(json.dumps(x)+'\n');p.stdin.flush()
send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'ai_quota_card','version':'1.0.0'}}})
s=selectors.DefaultSelector();s.register(p.stdout,selectors.EVENT_READ)
end=time.monotonic()+30
try:
 while time.monotonic()<end:
  if not s.select(1):continue
  line=p.stdout.readline()
  if not line: print('Server exited before response');break
  d=json.loads(line)
  if d.get('id')==1:
   send({'method':'initialized'});send({'id':2,'method':'account/rateLimits/read','params':{}})
  if d.get('id')==2:
   result=d.get('result',{})
   print(json.dumps({'rateLimits':result.get('rateLimits'), 'error':d.get('error')},ensure_ascii=False));break
 else: print('Timed out')
finally:
 p.terminate()
 try:p.wait(timeout=3)
 except subprocess.TimeoutExpired:p.kill()
