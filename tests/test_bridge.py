import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
spec = importlib.util.spec_from_file_location('bridge', ROOT / 'server/bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def test_literal_queue_no_shell(self):
        text = '中文 hello; $(touch /tmp/nope)\n`whoami`'
        with patch.object(bridge, 'run', return_value='queued') as run:
            bridge.dispatch(dict(op='queue', thread=str(uuid.uuid4()), text=text))
            args = run.call_args.args[0]
            self.assertEqual(args[-1], text)
            self.assertEqual(args[:3], ['codex', 'queue', '--thread'])
            self.assertNotIn('--resume', args)

    def test_invalid_thread_rejected(self):
        with self.assertRaises(ValueError):
            bridge.dispatch(dict(op='queue', thread=';uname', text='hello'))

    def test_control_characters_rejected(self):
        for text in ('', '\x1b[200~', 'abc\x00', 'a\r', 'a\x7f'):
            with self.assertRaises(ValueError):
                bridge.message_text(text)
        self.assertEqual(bridge.message_text('多行\n\t中文'), '多行\n\t中文')

    def test_send_requires_managed_pane(self):
        with patch.object(bridge, 'panes', return_value=[dict(id='%1', managed=False)]):
            with self.assertRaisesRegex(ValueError, 'read-only'):
                bridge.require_pane('%1', writing=True)

    def test_no_input_after_codex_exits(self):
        with patch.object(bridge, 'panes', return_value=[dict(id='%1', managed=True, pid=123)]), \
             patch.object(bridge, 'foreground_codex', return_value=False):
            with self.assertRaisesRegex(ValueError, 'foreground'):
                bridge.require_pane('%1', writing=True)

    def test_terminal_bracketed_paste(self):
        with patch.object(bridge, 'require_pane'), patch.object(bridge, 'tmux') as tmux:
            bridge.dispatch(dict(op='send', pane='%1', text='Enter\n你好'))
            calls = [c.args for c in tmux.call_args_list]
            self.assertEqual(calls[1], ('send-keys', '-t', '%1', '-l', '--', 'Enter\n你好'))
            self.assertEqual(calls[-1], ('send-keys', '-t', '%1', 'Enter'))

    def test_only_known_control_keys(self):
        with patch.object(bridge, 'require_pane'):
            with self.assertRaises(ValueError):
                bridge.dispatch(dict(op='key', pane='%1', key='arbitrary'))

    def test_dedup_and_uncertainty(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, HOME=home):
            req = dict(op='queue', requestID=str(uuid.uuid4()), text='hello')
            with patch.object(bridge, 'dispatch', return_value={'note': 'ok'}) as dispatch:
                self.assertEqual(bridge.handle(req), bridge.handle(req))
                self.assertEqual(dispatch.call_count, 1)
            req['text'] = 'changed'
            with self.assertRaisesRegex(ValueError, 'reused'):
                bridge.handle(req)
            req['requestID'] = str(uuid.uuid4())
            with patch.object(bridge, 'dispatch', side_effect=TimeoutError()):
                with self.assertRaises(TimeoutError):
                    bridge.handle(req)
            with self.assertRaisesRegex(ValueError, 'may have completed'):
                bridge.handle(req)

    def test_history_mapping(self):
        thread = {'turns': [{'items': [
            {'type': 'userMessage', 'id': '1', 'content': [{'type': 'text', 'text': '你好'}]},
            {'type': 'commandExecution', 'id': '2'},
            {'type': 'agentMessage', 'id': '3', 'text': '收到'}]}]}
        messages = bridge.history_messages(thread)
        self.assertEqual([m['role'] for m in messages], ['user', 'assistant'])
        self.assertEqual(messages[0]['text'], '你好')

    def test_paginated_history_order(self):
        with patch.object(bridge, 'rpc', return_value={'data': [
            {'turnId': 'turn1', 'item': {'type': 'agentMessage', 'id': '2', 'text': 'new'}},
            {'turnId': 'turn1', 'item': {'type': 'agentMessage', 'id': '1', 'text': 'old'}}]}) as rpc:
            result = bridge.dispatch(dict(op='history', thread=str(uuid.uuid4())))
            self.assertEqual([m['text'] for m in result['messages']], ['old', 'new'])
            self.assertEqual(rpc.call_args.args[0], 'thread/items/list')

    def test_wire_error_envelope(self):
        invalid = base64.b64encode(b'{"op":"unknown"}').decode()
        output = subprocess.check_output(['python3', str(ROOT / 'server/bridge.py'), invalid])
        result = json.loads(output)
        self.assertFalse(result['ok'])
        self.assertIn('Unknown', result['error'])


if __name__ == '__main__':
    unittest.main()
