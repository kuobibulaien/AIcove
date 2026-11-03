"""Local protocol fixture; no third-party packages or network access."""
import json
import os
import subprocess
import sys
import threading
import time

lock = threading.Lock()
calls = 0
cancelled = []
child = None


def send(request_id, result):
    data = (json.dumps({'jsonrpc': '2.0', 'id': request_id, 'result': result},
                       ensure_ascii=False) + '\n').encode()
    with lock:
        # Split a multibyte UTF-8 sequence, and coalesce the rest with a notice.
        index = data.find('晴'.encode())
        split = index + 1 if index >= 0 else min(7, len(data))
        sys.stdout.buffer.write(data[:split])
        sys.stdout.buffer.flush()
        time.sleep(.002)
        sys.stdout.buffer.write(data[split:] + b'{"jsonrpc":"2.0","method":"notifications/progress"}\n')
        sys.stdout.buffer.flush()


def delayed(request_id, name):
    time.sleep(.15 if name == 'slow' else .01)
    send(request_id, {'content': [{'type': 'text', 'text': name + '晴'}],
                      'structuredContent': {'ok': True}})


for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    params = request.get('params', {})
    request_id = request.get('id')
    if method == 'initialize':
        send(request_id, {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}},
                          'serverInfo': {'name': 'fixture', 'title': '本地测试'}})
    elif method == 'notifications/cancelled':
        cancelled.append(params['requestId'])
    elif method == 'tools/list':
        send(request_id, {'tools': [{'name': 'second' if params.get('cursor') else 'first'}],
                          **({} if params.get('cursor') else {'nextCursor': 'next'})})
    elif method == 'tools/call':
        calls += 1
        name = params['name']
        if name == 'exit':
            sys.stderr.write('failed ' + os.environ.get('SECRET_TOKEN', '') + '\n')
            sys.stderr.flush()
            sys.exit(7)
        elif name == 'invalid':
            print('not-json', flush=True)
        elif name == 'hang':
            pass
        elif name == 'spawn':
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
            send(request_id, {'structuredContent': {'child': child.pid, 'pid': os.getpid(),
                                                  'pgrp': os.getpgrp()}})
        elif name == 'status':
            send(request_id, {'structuredContent': {'calls': calls, 'cancelled': cancelled}})
        else:
            threading.Thread(target=delayed, args=(request_id, name), daemon=True).start()
