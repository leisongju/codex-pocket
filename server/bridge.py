#!/usr/bin/env python3
"""One JSON request per SSH exec. No listener, no credentials, no shell interpolation."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid

MAX_REQUEST = 180_000


def run(args, timeout=12):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise ValueError((p.stderr or p.stdout or 'Command failed')[:3000])
    return p.stdout


def tmux(*args):
    return run(['tmux', *args])


def panes():
    if not shutil.which('tmux'):
        return []
    p = subprocess.run(['tmux', 'list-panes', '-a', '-F',
                        '#{pane_id}\t#{session_name}\t#{pane_current_command}\t#{pane_pid}\t#{@codex_pocket}'],
                       capture_output=True, text=True, timeout=5)
    if p.returncode:
        return []
    result = []
    for line in p.stdout.splitlines():
        fields = line.split('\t')
        if len(fields) != 5:
            continue
        pane, session, command, pid, managed = fields
        result.append(dict(id=pane, session=session, command=command,
                           pid=int(pid), managed=managed == '1'))
    return result


def require_pane(pane, writing=False):
    if not isinstance(pane, str) or not re.fullmatch(r'%\d+', pane):
        raise ValueError('Invalid pane ID')
    entry = next((p for p in panes() if p['id'] == pane), None)
    if entry is None:
        raise ValueError('Pane no longer exists')
    if writing and not entry['managed']:
        raise ValueError('Pane is read-only. Enable it on the server with bridge.py --adopt %N')
    if writing and not foreground_codex(entry['pid']):
        raise ValueError('Codex is not the foreground process; refusing to type into a shell or tool')
    return entry


def foreground_codex(pane_pid):
    """Require a codex process in the terminal's foreground process group."""
    try:
        # /proc/PID/stat field 8 = foreground process group; comm may contain spaces.
        fields = Path(f'/proc/{pane_pid}/stat').read_text().rsplit(')', 1)[1].split()
        foreground_group = int(fields[5])
        if foreground_group <= 0:
            return False
        for path in Path('/proc').glob('[0-9]*/stat'):
            try:
                stat = path.read_text().rsplit(')', 1)[1].split()
                if int(stat[2]) != foreground_group:
                    continue
                cmd = (path.parent / 'cmdline').read_bytes().split(b'\0')
                # Native codex binary or node launcher; do not match arbitrary prompt text.
                executable = Path(cmd[0].decode()).name if cmd else ''
                launcher = Path(cmd[1].decode()).name if len(cmd) > 1 else ''
                if executable == 'codex' or (executable == 'node' and launcher in ('codex', 'codex.js')):
                    return True
            except (OSError, ValueError, IndexError, UnicodeError):
                continue
    except (OSError, ValueError, IndexError):
        pass
    return False


def rpc(method, params):
    from runtime import request
    return request(dict(op='rpc', method=method, params=json.dumps(params)))


def thread_id(value):
    return str(uuid.UUID(value))


def message_text(value):
    if not isinstance(value, str) or not value.strip() or len(value.encode()) > 32_000:
        raise ValueError('Message must be 1–32000 bytes')
    if any(ord(c) < 32 and c not in '\n\t' for c in value) or '\x7f' in value:
        raise ValueError('Control characters are not allowed in messages')
    return value


def history_messages(thread):
    messages = []
    for turn in thread.get('turns', []):
        for item in turn.get('items', []):
            kind = item.get('type')
            if kind == 'userMessage':
                text = '\n'.join(c.get('text', '') for c in item.get('content', []) if c.get('type') == 'text')
                role = 'user'
            elif kind == 'agentMessage':
                text, role = item.get('text', ''), 'assistant'
            else:
                continue
            messages.append(dict(id=item.get('id', str(len(messages))), role=role, text=text))
    # Keep SSH response comfortably bounded. Full history remains on server.
    return messages[-300:]


def dispatch(req):
    op = req.get('op')
    if op in ('models', 'history_v2', 'new_thread', 'turn', 'interrupt', 'answer', 'image', 'upload_prepare', 'upload_chunk'):
        from runtime import request
        return request(req)
    if op == 'status':
        version = run(['codex', '--version']).strip()
        help_text = subprocess.run(['codex', 'queue', '--help'], capture_output=True,
                                   text=True, timeout=10)
        return dict(version=version, queue=help_text.returncode == 0 and '--thread' in help_text.stdout,
                    panes=panes())
    if op == 'panes':
        return dict(panes=panes())
    if op == 'screen':
        pane = req.get('pane')
        require_pane(pane)
        return dict(text=tmux('capture-pane', '-p', '-J', '-t', pane, '-S', '-200'))
    if op == 'threads':
        params = dict(limit=50, sortKey='updated_at')
        if req.get('cursor'):
            params['cursor'] = str(req['cursor'])
        result = rpc('thread/list', params)
        return dict(threads=[dict(id=t['id'], title=t.get('name') or t.get('preview') or t['id'],
                                  cwd=t.get('cwd', ''), updatedAt=t.get('updatedAt', 0))
                             for t in result.get('data', [])], nextCursor=result.get('nextCursor'))
    if op == 'history':
        ident = thread_id(req['thread'])
        try:
            # 0.167 paginated history: read recent items across all turns.
            result = rpc('thread/items/list', dict(threadId=ident, limit=300, sortDirection='desc'))
            items = [entry['item'] for entry in result.get('data', [])]
            return dict(messages=history_messages({'turns': [{'items': list(reversed(items))}]}))
        except ValueError as exc:
            # Older servers may not implement pagination. Other failures stay visible.
            if not any(marker in str(exc).lower() for marker in ('method not found', '-32601', 'unknown method')):
                raise
            result = rpc('thread/read', dict(threadId=ident, includeTurns=True))
            return dict(messages=history_messages(result.get('thread', {})))
    if op == 'queue':
        # Intentionally do not --resume: never start another owner of a running thread.
        text = message_text(req.get('text'))
        output = run(['codex', 'queue', '--thread', thread_id(req['thread']), '--message', text], timeout=25)
        return dict(note=output.strip() or 'Message queued. A stopped thread must be resumed separately.')
    if op in ('send', 'key'):
        pane = req.get('pane')
        require_pane(pane, writing=True)
        if op == 'key':
            key = req.get('key')
            if key not in ('Enter', 'Escape', 'Up', 'Down', 'Left', 'Right', 'Tab', 'C-c'):
                raise ValueError('Unsupported key')
            tmux('send-keys', '-t', pane, key)
        else:
            text = message_text(req.get('text'))
            # Bracketed paste keeps multiline prompts and key names literal.
            tmux('send-keys', '-t', pane, '-H', '1b', '5b', '32', '30', '30', '7e')
            for offset in range(0, len(text), 2000):
                tmux('send-keys', '-t', pane, '-l', '--', text[offset:offset + 2000])
            tmux('send-keys', '-t', pane, '-H', '1b', '5b', '32', '30', '31', '7e')
            tmux('send-keys', '-t', pane, 'Enter')
        return dict(note='Sent to terminal')
    raise ValueError('Unknown operation')


def handle(req):
    if not isinstance(req, dict):
        raise ValueError('Expected JSON object')
    if req.get('op') not in ('send', 'key', 'queue', 'turn', 'new_thread', 'answer', 'interrupt'):
        return dispatch(req)
    # Record before sending: interrupted requests are never silently replayed.
    request_id = str(uuid.UUID(req['requestID']))
    digest = hashlib.sha256(json.dumps(req, sort_keys=True).encode()).hexdigest()
    state = Path.home() / '.local/state/codex-pocket'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state, 0o700)
    with (state / 'requests.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        log = state / (request_id + '.json')
        if log.exists():
            old = json.loads(log.read_text())
            if old['digest'] != digest:
                raise ValueError('Request ID reused for different input')
            if old.get('done'):
                return old['result']
            raise ValueError('Previous send may have completed. Check the conversation before sending again.')
        record = dict(digest=digest, done=False)
        log.write_text(json.dumps(record))
        try:
            result = dispatch(req)
        except Exception:
            # Keep uncertainty marker even if only part of terminal input was written.
            raise
        record.update(done=True, result=result)
        log.write_text(json.dumps(record))
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('request', nargs='?')
    parser.add_argument('--adopt', metavar='%PANE')
    args = parser.parse_args()
    if args.adopt:
        entry = require_pane(args.adopt)
        if not foreground_codex(entry['pid']):
            raise ValueError('Codex must be running in the foreground of this pane')
        tmux('set-option', '-p', '-t', args.adopt, '@codex_pocket', '1')
        print('Enabled mobile input for ' + args.adopt)
        return
    try:
        if not args.request or len(args.request) > MAX_REQUEST:
            raise ValueError('Invalid request size')
        req = json.loads(base64.b64decode(args.request, validate=True))
        result = dict(ok=True, data=handle(req))
    except Exception as e:
        result = dict(ok=False, error=str(e)[:3000])
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
