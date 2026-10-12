"""Exercise the real Network.framework relay with controllable POSIX TCP peers."""
import concurrent.futures, hashlib, json, os, queue, socket, struct, subprocess, threading, time
from pathlib import Path

class Harness:
    def __init__(self, target, requested=0):
        self.process = subprocess.Popen(['build/relay-harness', str(target), str(requested)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.events=queue.Queue(); self.latest={}
        def reader():
            for line in self.process.stdout:
                try: self.events.put(json.loads(line))
                except ValueError: pass
        self.reader=threading.Thread(target=reader,daemon=True); self.reader.start()
        self.port=None
        result=self.wait(lambda value: value.get('kind') in ('ready','error'))
        if result['kind']=='error':print('INFO listener error', result, flush=True)
    def wait(self, condition, timeout=15):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            value=self.events.get(timeout=max(.01,end-time.monotonic()))
            if value['kind']=='stats': self.latest=value
            if value['kind']=='ready': self.port=value['port']
            if condition(value): return value
        raise AssertionError('Relay event timeout')
    def stop(self):
        if self.process.poll() is None:
            self.process.stdin.write('stop\n'); self.process.stdin.flush()
            self.process.wait(timeout=5)
        self.reader.join(timeout=2)

        while not self.events.empty():
            value=self.events.get()
            if value['kind']=='stats':self.latest=value
        return self.latest

class Server:
    def __init__(self, slow=False):
        self.sock=socket.socket(); self.sock.bind(('127.0.0.1',0)); self.sock.listen(128); self.sock.settimeout(.2)
        self.port=self.sock.getsockname()[1]; self.closed=False; self.slow=slow; self.errors=[]
        def serve():
            while not self.closed:
                try: client,_=self.sock.accept()
                except socket.timeout: continue
                except OSError: break
                threading.Thread(target=self.client,args=(client,),daemon=True).start()
        self.thread=threading.Thread(target=serve,daemon=True);self.thread.start()
    def client(self, client):
        try:
            client.settimeout(10)
            data=bytearray()
            while True:
                part=client.recv(65536)
                if not part:break
                data.extend(part)
                if self.slow:time.sleep(.001)
            # Reply only after input EOF: proves upload half-close leaves download open.
            client.sendall(data)
            client.shutdown(socket.SHUT_WR)
        except (OSError,TimeoutError) as error:self.errors.append(type(error).__name__)
        finally:client.close()
    def close(self):
        self.closed=True;self.sock.close();self.thread.join(timeout=1)

def transfer(port, data, slow_reader=False):
    started=time.monotonic()
    with socket.create_connection(('127.0.0.1',port),timeout=10) as client:
        client.settimeout(15); client.sendall(data); client.shutdown(socket.SHUT_WR)
        received=bytearray()
        while True:
            part=client.recv(65536)
            if not part:break
            received.extend(part)
            if slow_reader:time.sleep(.001)
    assert bytes(received)==data, f'Byte stream modified/truncated: received={len(received)} expected={len(data)}'
    return time.monotonic()-started

def check(name, condition):
    if not condition: raise AssertionError(name)
    print('PASS '+name,flush=True)

server=Server(slow=True); harness=None
try:
    harness=Harness(server.port); assert harness.port
    payload=os.urandom(512*1024)+b'\x00HTTP/1.1\r\n\x05\x01\x00\x16\x03\x03'
    transfer(harness.port,payload)
    harness.wait(lambda value:value.get('up')==len(payload) and value.get('down')==len(payload))
    check('single upload/download exact counters and opaque bytes',harness.latest['up']==len(payload))
    check('request EOF followed by full response / half-close',harness.latest['down']==len(payload))
    harness.wait(lambda value:value.get('kind')=='stats' and value['upRate']==0 and value['downRate']==0 and value['connections']==0)
    check('idle rates zero and pairs released',harness.latest['connections']==0)
    sizes=[131072+i*113 for i in range(8)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda size:transfer(harness.port,os.urandom(size)),sizes))
    total=len(payload)+sum(sizes)
    harness.wait(lambda value:value.get('up')==total and value.get('down')==total)
    check('8 concurrent connections aggregate without double counting',harness.latest['up']==total and harness.latest['down']==total)
    large=os.urandom(16*1024*1024)
    direct=transfer(server.port,large,True); relayed=transfer(harness.port,large,True)
    total+=len(large)
    harness.wait(lambda value:value.get('up')==total and value.get('down')==total)
    check('16 MiB slow peer integrity and backpressure',harness.latest['up']==total)
    Path('build/relay-metrics-live.json').write_text(json.dumps(harness.latest))
    print(f'INFO 16 MiB direct={direct:.3f}s relay={relayed:.3f}s ratio={relayed/direct:.2f}',flush=True)
    check('large transfer overhead below broad regression threshold',relayed<max(direct*3,direct+2))
    addresses=subprocess.check_output(['lsof','-nP','-a','-p',str(harness.process.pid),'-iTCP','-sTCP:LISTEN'],text=True)
    check('listener bound only to IPv4 loopback',f'127.0.0.1:{harness.port}' in addresses and '*:' not in addresses and '[::]:' not in addresses)
    other=Harness(server.port,harness.port)
    check('occupied relay port rejected',other.port is None and other.process.wait(timeout=5)!=0)
    live=socket.create_connection(('127.0.0.1',harness.port));live.sendall(os.urandom(20000));live.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));live.close()
    harness.wait(lambda value:value.get('kind')=='stats' and value['connections']==0)
    check('reset peer cleanup',harness.latest['connections']==0)
    final=harness.stop();check('stop rates zero / retain final totals / no active pairs',not final['running'] and final['upRate']==0 and final['downRate']==0 and final['connections']==0 and final['up']>=total)
    try:socket.create_connection(('127.0.0.1',harness.port),timeout=.3)
    except OSError:check('stop closes listening socket',True)
    else:raise AssertionError('Relay still accepts after stop')
    fresh=Harness(server.port,harness.port)
    fresh.wait(lambda value:value.get('kind')=='stats' and value['running'])
    check('restart creates fresh zero counters',fresh.latest.get('up')==0 and fresh.latest.get('down')==0)
    transfer(fresh.port,b'session-reset-check')
    fresh.wait(lambda value:value.get('up')==len(b'session-reset-check') and value.get('down')==len(b'session-reset-check'))
    check('fresh session counts only fresh traffic',fresh.latest['up']==len(b'session-reset-check'))
    open_client=socket.create_connection(('127.0.0.1',fresh.port));open_client.sendall(b'pending')
    final=fresh.stop()
    open_client.settimeout(2)
    try:closed=open_client.recv(1)==b''
    except ConnectionResetError:closed=True
    open_client.close()
    check('cancel closes active connections and listener',closed and final['connections']==0)
    unavailable=socket.socket();unavailable.bind(('127.0.0.1',0));port=unavailable.getsockname()[1];unavailable.close()
    failed=Harness(port)
    with socket.create_connection(('127.0.0.1',failed.port)) as client:
        client.settimeout(3)
        try:received=client.recv(1)
        except ConnectionResetError:received=b''
        check('unavailable target closes accepted connection',received==b'')
    failed.wait(lambda value:value.get('kind')=='stats' and value['connections']==0)
    failed.stop()
    cancelled=subprocess.run(['build/relay-harness',str(server.port),'0','cancel'],text=True,capture_output=True,timeout=6)
    check('startup cancellation finishes without leaked listener',cancelled.returncode!=0 and '"kind":"error"' in cancelled.stdout)
    print('RESULT: PASS',flush=True)
finally:
    if harness and harness.process.poll() is None:harness.stop()
    server.close()
