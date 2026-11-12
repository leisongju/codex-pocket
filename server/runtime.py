#!/usr/bin/env python3
"""Persistent app-server transport, reachable only over a per-user Unix socket."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import socket
import socketserver
import subprocess
import sys
import threading
import time
import uuid
from presentation import present

STATE = Path.home() / '.local/state/codex-pocket'
MAX_FRAME = 24 * 1024 * 1024


class RPCError(ValueError):
    pass


class RPCConnection:
    def __init__(self, command, notify):
        self.notify = notify
        self.pending = {}
        self.lock = threading.RLock()
        self.sequence = 0
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        threading.Thread(target=self.read, daemon=True).start()
        try:
            self.request('initialize', {'clientInfo': {'name': 'codex_pocket', 'version': '0.2.0'},
                                        'capabilities': {'experimentalApi': True}}, timeout=15)
            self.write({'method': 'initialized', 'params': {}})
        except Exception:
            self.close()
            raise

    def write(self, value):
        with self.lock:
            self.process.stdin.write((json.dumps(value) + '\n').encode())
            self.process.stdin.flush()

    def request(self, method, params, timeout=35):
        with self.lock:
            self.sequence += 1
            ident = 'pocket-' + str(self.sequence)
            response = queue.Queue(maxsize=1)
            self.pending[ident] = response
        try:
            self.write({'id': ident, 'method': method, 'params': params})
            try:
                value = response.get(timeout=timeout)
            except queue.Empty:
                raise RPCError('Codex request timed out: ' + method)
            if 'error' in value:
                raise RPCError(json.dumps(value['error'], ensure_ascii=False))
            return value.get('result', {})
        finally:
            with self.lock:
                self.pending.pop(ident, None)

    def read(self):
        try:
            while True:
                line = self.process.stdout.readline(MAX_FRAME + 1)
                if not line or len(line) > MAX_FRAME:
                    break
                try:
                    value = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                with self.lock:
                    response = self.pending.get(value.get('id'))
                if response and ('result' in value or 'error' in value):
                    response.put(value)
                elif 'method' in value:
                    self.notify(value)
        finally:
            with self.lock:
                for response in self.pending.values():
                    try:
                        response.put_nowait({'error': {'message': 'Codex transport disconnected'}})
                    except queue.Full:
                        pass
            self.process.stdout.close()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.process.stdin:
            self.process.stdin.close()


class Session:
    def __init__(self):
        self.connection = None
        self.start_lock = threading.Lock()
        self.lock = threading.RLock()
        self.mode = 'disconnected'
        self.live = {}
        self.active = {}
        self.approvals = {}
        self.assets = {}
        self.owned = set()
        self.models_cache = None
        self.cwd = {}

    def rpc(self, method, params):
        with self.start_lock:
            if self.connection is None or self.connection.process.poll() is not None:
                self.connection = None
                with self.lock:
                    self.approvals.clear()
                    self.active.clear()
                    self.live.clear()
                # Attach to the same local daemon first; do not launch a second owner of its threads.
                for mode, command in [('shared', ['codex', 'app-server', 'proxy']),
                                      ('isolated', ['codex', 'app-server'])]:
                    try:
                        self.connection = RPCConnection(command, self.notify)
                        self.mode = mode
                        break
                    except Exception:
                        # RPCConnection initialization may have exited before a usable connection.
                        continue
                if self.connection is None:
                    raise RPCError('Unable to initialize Codex app-server')
        return self.connection.request(method, params)

    def notify(self, value):
        method, params = value['method'], value.get('params') or {}
        thread = params.get('threadId', '')
        with self.lock:
            if 'id' in value:
                token = str(uuid.uuid4())
                self.approvals[token] = dict(id=token, rpcID=value['id'], threadID=thread,
                                             method=method, params=params)
                return
            if method == 'turn/started':
                self.active[thread] = params.get('turn', {}).get('id', '')
                # Older turns remain in persisted history; only retain the current live turn.
                self.live[thread] = {}
            elif method == 'turn/completed':
                self.active.pop(thread, None)
                turn = params.get('turn', {})
                if turn.get('error'):
                    self.live.setdefault(thread, {})['turn-error'] = {
                        'type': 'error', 'id': 'turn-error-' + turn.get('id', ''),
                        'message': turn['error']}
            elif method in ('item/started', 'item/completed'):
                item = params.get('item', {})
                self.live.setdefault(thread, {})[item.get('id', '')] = item
            elif method == 'item/agentMessage/delta':
                ident = params.get('itemId', '')
                item = self.live.setdefault(thread, {}).setdefault(ident, {
                    'id': ident, 'type': 'agentMessage', 'text': '', 'status': 'inProgress'})
                item['text'] = item.get('text', '') + params.get('delta', '')
            elif method == 'item/commandExecution/outputDelta':
                item = self.live.setdefault(thread, {}).get(params.get('itemId', ''))
                if item:
                    item['aggregatedOutput'] = ((item.get('aggregatedOutput') or '') + params.get('delta', ''))[-64000:]
            elif method == 'serverRequest/resolved':
                request_id = params.get('requestId')
                self.approvals = {k: v for k, v in self.approvals.items() if v['rpcID'] != request_id}

    def asset(self, thread, source):
        if not source.startswith(('data:', 'https:', 'http:')):
            path = Path(source).expanduser()
            if not path.is_absolute():
                path = Path(self.cwd.get(thread, str(Path.home()))) / path
            source = str(path.resolve())
        ident = hashlib.sha256((thread + '\0' + source).encode()).hexdigest()
        self.assets[(thread, ident)] = source
        return dict(id=ident, source=ident, local=True)

    def render(self, thread, entries):
        return [present(e.get('item', e), e.get('turnId', ''),
                        lambda source: self.asset(thread, source)) for e in entries]

    def catalog(self):
        if self.models_cache and time.monotonic() - self.models_cache[0] < 60:
            return self.models_cache[1]
        models, cursor = [], None
        for _ in range(30):
            params = dict(limit=100, includeHidden=False)
            if cursor:
                params['cursor'] = cursor
            result = self.rpc('model/list', params)
            models.extend(m for m in result.get('data', []) if not m.get('hidden'))
            cursor = result.get('nextCursor')
            if not cursor:
                break
        self.models_cache = (time.monotonic(), models)
        return models

    def options(self, req):
        model_id = req.get('model')
        if not model_id:
            return {}
        model = next((m for m in self.catalog() if m['model'] == model_id), None)
        if not model:
            raise RPCError('Selected model is not available')
        result = dict(model=model_id)
        effort = req.get('effort')
        if effort:
            if effort not in [v['reasoningEffort'] for v in model.get('supportedReasoningEfforts', [])]:
                raise RPCError('Selected reasoning effort is unsupported')
            result['effort'] = effort
        tier = req.get('tier')
        if tier:
            allowed = ['default'] + [v['id'] for v in model.get('serviceTiers', [])]
            if tier not in allowed:
                raise RPCError('Selected service tier is unsupported')
            result['serviceTier'] = tier
        return result

    def ensure_loaded(self, thread):
        # An isolated fallback must never resume an externally owned/running thread.
        if self.mode != 'shared' and thread not in self.owned:
            raise RPCError('当前会话不属于手机连接的共享 Codex 服务。请连接共享 daemon，或在手机新建会话；不会复制运行中的会话。')
        self.rpc('thread/resume', dict(threadId=thread, excludeTurns=True))

    def handle(self, req):
        op = req['op']
        if op == 'models':
            return dict(models=self.catalog(), mode=self.mode)
        if op == 'history_v2':
            thread = str(uuid.UUID(req['thread']))
            params = dict(threadId=thread, limit=80, sortDirection='desc')
            if req.get('cursor'):
                params['cursor'] = req['cursor']
            metadata = self.rpc('thread/read', dict(threadId=thread))['thread']
            self.cwd[thread] = metadata.get('cwd', str(Path.home()))
            page = self.rpc('thread/items/list', params)
            entries = list(reversed(page.get('data', [])))
            # Copy mutable stream state before rendering to avoid concurrent delta mutation.
            with self.lock:
                live = json.loads(json.dumps(self.live.get(thread, {})))
                approvals = [dict(id=a['id'], threadID=a['threadID'], method=a['method'], params=a['params'])
                             for a in self.approvals.values() if a['threadID'] == thread]
                turn = self.active.get(thread)
            if not req.get('cursor'):
                known = {e['item']['id'] for e in entries}
                entries = [dict(item=live.get(e['item']['id'], e['item']), turnId=e.get('turnId', '')) for e in entries]
                entries.extend(dict(item=v, turnId=turn or '') for k, v in live.items() if k not in known)
            return dict(items=self.render(thread, entries), nextCursor=page.get('nextCursor'),
                        approvals=approvals, activeTurn=turn, mode=self.mode,
                        controllable=self.mode == 'shared' or thread in self.owned)
        if op == 'new_thread':
            cwd = str(Path(req['cwd']).expanduser().resolve(strict=True))
            if not Path(cwd).is_dir():
                raise RPCError('Project directory does not exist')
            options = self.options(req)
            options.pop('effort', None)  # Applied on turn/start, not thread/start.
            result = self.rpc('thread/start', dict(cwd=cwd, **options))
            thread = result['thread']
            self.cwd[thread['id']] = thread.get('cwd', cwd)
            self.owned.add(thread['id'])
            return dict(thread=dict(id=thread['id'], title=thread.get('name') or '新对话', cwd=thread.get('cwd', cwd)))
        if op == 'turn':
            thread = str(uuid.UUID(req['thread']))
            text = req.get('text', '')
            if len(text.encode()) > 32000:
                raise RPCError('Message too long')
            inputs = []
            if text.strip():
                inputs.append(dict(type='text', text=text))
            photos = json.loads(req.get('photos', '[]'))
            if len(photos) > 6:
                raise RPCError('At most six images per message')
            for token in photos:
                source = STATE / 'uploads' / (str(uuid.UUID(token)) + '.jpg')
                validate_image(source)
                inputs.append(dict(type='localImage', path=str(source)))
            if not inputs:
                raise RPCError('Empty message')
            options = self.options(req)
            if self.connection is None:
                self.rpc('thread/read', dict(threadId=thread))
            if self.mode != 'shared' and thread not in self.owned:
                if options or photos:
                    raise RPCError('此会话仅支持文字排队。要更改模型或发送图片，请连接共享 daemon，或在手机新建会话。')
                output = subprocess.run(['codex', 'queue', '--thread', thread, '--message', text],
                                        capture_output=True, text=True, timeout=30)
                if output.returncode:
                    raise RPCError(output.stderr[:3000])
                return dict(note='已入队；等待原会话接收', turnID=None)
            self.ensure_loaded(thread)
            result = self.rpc('turn/start', dict(threadId=thread, input=inputs,
                                                clientUserMessageId=req['requestID'], **options))
            turn = result.get('turn', {})
            self.active[thread] = turn.get('id', '')
            return dict(note='已发送', turnID=turn.get('id'))
        if op == 'interrupt':
            thread = str(uuid.UUID(req['thread']))
            turn = self.active.get(thread)
            if not turn:
                raise RPCError('No active turn available to interrupt')
            self.rpc('turn/interrupt', dict(threadId=thread, turnId=turn))
            return dict(note='已请求停止')
        if op == 'answer':
            token = req['approval']
            with self.lock:
                approval = self.approvals.get(token)
            if not approval or approval['threadID'] != req['thread']:
                raise RPCError('This request is no longer pending')
            method = approval['method']
            if method in ('item/commandExecution/requestApproval', 'item/fileChange/requestApproval'):
                decision = req['decision']
                if decision not in ('accept', 'decline'):
                    raise RPCError('Unsupported approval decision')
                result = dict(decision=decision)
            elif method == 'item/tool/requestUserInput':
                answers = json.loads(req['answers'])
                for question in approval['params'].get('questions', []):
                    answer = answers.get(question['id'], {}).get('answers')
                    if not isinstance(answer, list) or not answer or not all(isinstance(x, str) and x.strip() for x in answer):
                        raise RPCError('Please answer every question')
                result = dict(answers=answers)
            else:
                raise RPCError('This request type must be handled in the original Codex client')
            self.connection.write(dict(id=approval['rpcID'], result=result))
            with self.lock:
                self.approvals.pop(token, None)
            return dict(note='已提交')
        if op == 'image':
            source = self.assets.get((req['thread'], req['asset']))
            if not source:
                raise RPCError('Image reference expired; refresh this conversation')
            if source.startswith('data:image/'):
                data = base64.b64decode(source.split(',', 1)[1], validate=True)
                if len(data) > 8_000_000:
                    raise RPCError('Image larger than 8 MB')
            else:
                data = validate_image(Path(source).expanduser())
            return dict(base64=base64.b64encode(data).decode())
        if op == 'upload_prepare':
            uploads = STATE / 'uploads'
            uploads.mkdir(mode=0o700, exist_ok=True)
            token = str(uuid.uuid4())
            path = uploads / (token + '.jpg')
            path.touch(mode=0o600, exist_ok=False)
            return dict(token=token)
        if op == 'upload_chunk':
            path = STATE / 'uploads' / (str(uuid.UUID(req['token'])) + '.jpg')
            chunk = base64.b64decode(req['data'], validate=True)
            if len(chunk) > 36000:
                raise RPCError('Image chunk too large')
            with path.open('r+b') as file:
                file.seek(0, 2)
                if file.tell() != int(req['offset']) or file.tell() + len(chunk) > 8_000_000:
                    raise RPCError('Invalid image offset or size')
                file.write(chunk)
            return dict(note='ok')
        if op == 'rpc':
            method = req['method']
            if method not in ('thread/list', 'thread/read', 'thread/items/list'):
                raise RPCError('RPC method is not allowed')
            return self.rpc(method, json.loads(req['params']))
        raise RPCError('Unknown session operation')


def validate_image(path):
    if not path.is_file() or path.stat().st_size > 8_000_000:
        raise RPCError('Image missing or larger than 8 MB')
    data = path.read_bytes()
    if not (data.startswith(b'\xff\xd8\xff') or data.startswith(b'\x89PNG\r\n\x1a\n')
            or data.startswith((b'GIF87a', b'GIF89a')) or (data.startswith(b'RIFF') and data[8:12] == b'WEBP')):
        raise RPCError('Unsupported image format')
    return data


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    session = None


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            line = self.rfile.readline(MAX_FRAME + 1)
            if len(line) > MAX_FRAME:
                raise RPCError('Request too large')
            result = dict(ok=True, data=self.server.session.handle(json.loads(line)))
        except Exception as error:
            result = dict(ok=False, error=str(error)[:3000])
        self.wfile.write((json.dumps(result, ensure_ascii=False) + '\n').encode())


def socket_path():
    # Keep sockaddr_un under Linux's 108-byte limit, including long home directories.
    return Path('/tmp') / ('codex-pocket-' + str(os.getuid())) / 'session.sock'


def request(req):
    state = STATE
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = socket_path().parent
    folder.mkdir(mode=0o700, exist_ok=True)
    if folder.stat().st_uid != os.getuid() or folder.stat().st_mode & 0o077:
        raise RPCError('Unsafe Unix socket directory permissions')
    def connect():
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(90)
        try:
            connection.connect(str(socket_path()))
            return connection
        except Exception:
            connection.close()
            raise
    with (state / 'daemon.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            connection = connect()
        except (FileNotFoundError, ConnectionRefusedError):
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--serve'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
            for attempt in range(100):
                try:
                    connection = connect()
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    time.sleep(.05)
            else:
                raise RPCError('Unable to start local session bridge')
    with connection:
        connection.sendall((json.dumps(req) + '\n').encode())
        with connection.makefile('rb') as response:
            data = response.readline(MAX_FRAME + 1)
        if len(data) > MAX_FRAME:
            raise RPCError('Response too large')
        result = json.loads(data)
        if not result['ok']:
            raise RPCError(result['error'])
        return result['data']


def serve():
    os.umask(0o077)
    path = socket_path()
    if path.exists():
        path.unlink()
    server = Server(str(path), Handler)
    server.session = Session()
    os.chmod(path, 0o600)
    try:
        server.serve_forever()
    finally:
        if server.session.connection:
            server.session.connection.close()
        server.server_close()
        path.unlink(missing_ok=True)


if __name__ == '__main__' and '--serve' in sys.argv:
    serve()
