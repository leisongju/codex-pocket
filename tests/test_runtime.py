import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
from runtime import RPCConnection, RPCError, Session, validate_image
from presentation import present

THREAD = str(uuid.uuid4())
MODEL = dict(id='m', model='actual-model', displayName='Available model', description='test',
             defaultReasoningEffort='medium', hidden=False,
             supportedReasoningEfforts=[dict(reasoningEffort='medium', description='normal'),
                                        dict(reasoningEffort='high', description='complex')],
             serviceTiers=[dict(id='priority', name='Fast', description='faster')])


class PresentationTests(unittest.TestCase):
    def test_image_only_user_is_visible(self):
        value = present(dict(id='1', type='userMessage', content=[dict(type='image', url='https://example.com/a.png')]))
        self.assertEqual(value['importance'], 'visible')
        self.assertEqual(len(value['images']), 1)
        self.assertEqual(value['text'], '')

    def test_success_collapses_error_does_not(self):
        value = dict(id='1', type='commandExecution', command='python tests.py', exitCode=0)
        self.assertEqual(present(value)['importance'], 'collapsed')
        value['exitCode'] = 1
        self.assertEqual(present(value)['importance'], 'attention')

    def test_reasoning_summary_only(self):
        result = present(dict(id='r', type='reasoning', summary=['published summary'], content=['not displayed by compact policy']))
        self.assertEqual(result['text'], 'published summary')
        self.assertEqual(result['importance'], 'collapsed')

    def test_completed_progress_collapses_but_final_does_not(self):
        progress = dict(id='a', type='agentMessage', text='Working on it', phase='commentary')
        self.assertEqual(present(progress)['importance'], 'collapsed')
        progress['phase'] = 'final_answer'
        self.assertEqual(present(progress)['importance'], 'visible')

    def test_assistant_questions_remain_visible(self):
        value = present(dict(id='q', type='agentMessage', text='Question', phase='commentary',
                             questions=[dict(title='Choose', options=['A', 'B'])]))
        self.assertEqual(value['importance'], 'visible')
        self.assertEqual(value['questions'][0]['options'], ['A', 'B'])

    def test_generated_image_uses_official_saved_path(self):
        register = Mock(return_value=dict(id='asset', source='asset', local=True))
        result = present(dict(id='i', type='imageGeneration', savedPath='/tmp/output.png'), register_asset=register)
        register.assert_called_once_with('/tmp/output.png')
        self.assertEqual(len(result['images']), 1)

    def test_failed_file_change_is_prominent(self):
        value = present(dict(id='f', type='fileChange', changes=[], status='failed'))
        self.assertEqual(value['importance'], 'attention')

    def test_unknown_type_retained(self):
        result = present(dict(id='new', type='futureType', payload='important'))
        self.assertIn('important', result['text'])
        self.assertEqual(result['title'], 'futureType')

    def test_markdown_images_not_lost(self):
        register = Mock(return_value=dict(id='1', source='asset', local=True))
        result = present(dict(id='a', type='agentMessage', text='图：![进度](report/chart.png)'), register_asset=register)
        self.assertEqual(result['text'], '图：进度')
        self.assertEqual(len(result['images']), 1)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.session = Session()
        self.session.mode = 'shared'
        self.session.connection = Mock()
        self.session.catalog = Mock(return_value=[MODEL])

    def test_model_effort_fast_really_forwarded(self):
        self.session.rpc = Mock(return_value={'turn': {'id': 'turn-1'}})
        req = dict(op='turn', thread=THREAD, text='你好\n多行', model='actual-model', effort='high',
                   tier='priority', requestID=str(uuid.uuid4()))
        self.session.handle(req)
        method, params = self.session.rpc.call_args.args
        self.assertEqual(method, 'turn/start')
        self.assertEqual(params['model'], 'actual-model')
        self.assertEqual(params['effort'], 'high')
        self.assertEqual(params['serviceTier'], 'priority')
        self.assertEqual(params['input'][0]['text'], '你好\n多行')
        self.assertEqual(params['clientUserMessageId'], req['requestID'])

    def test_invalid_model_capabilities_rejected(self):
        for fields in [dict(model='unavailable'), dict(model='actual-model', effort='ultra'),
                       dict(model='actual-model', tier='made-up-fast')]:
            with self.assertRaises(RPCError):
                self.session.options(fields)

    def test_default_tier_resets_fast(self):
        self.assertEqual(self.session.options(dict(model='actual-model', tier='default'))['serviceTier'], 'default')

    def test_streamed_deltas_merge_and_complete(self):
        s = self.session
        s.notify(dict(method='turn/started', params=dict(threadId=THREAD, turn={'id': 't'})))
        for text in ('你', '好'):
            s.notify(dict(method='item/agentMessage/delta', params=dict(threadId=THREAD, itemId='a', delta=text)))
        self.assertEqual(s.live[THREAD]['a']['text'], '你好')
        self.assertEqual(s.active[THREAD], 't')
        s.notify(dict(method='turn/completed', params=dict(threadId=THREAD, turn={'id': 't'})))
        self.assertNotIn(THREAD, s.active)

    def test_paging_order_and_live_update(self):
        s = self.session
        s.rpc = Mock(side_effect=[{'thread': {'cwd': '/home/user/project'}}, {'data': [
            dict(turnId='t', item=dict(id='new', type='agentMessage', text='new')),
            dict(turnId='t', item=dict(id='old', type='userMessage', content=[]))], 'nextCursor': 'older'}])
        s.live[THREAD] = {'new': dict(id='new', type='agentMessage', text='streamed')}
        result = s.handle(dict(op='history_v2', thread=THREAD))
        self.assertEqual([x['id'] for x in result['items']], ['old', 'new'])
        self.assertEqual(result['items'][-1]['text'], 'streamed')
        self.assertEqual(result['nextCursor'], 'older')
        self.assertEqual(s.cwd[THREAD], '/home/user/project')

    def test_isolated_transport_never_resumes_external_thread(self):
        self.session.mode = 'isolated'
        self.session.rpc = Mock()
        with self.assertRaises(RPCError):
            self.session.ensure_loaded(THREAD)
        self.session.rpc.assert_not_called()

    def test_isolated_transport_can_resume_its_own_thread(self):
        self.session.mode = 'isolated'
        self.session.owned.add(THREAD)
        self.session.rpc = Mock()
        self.session.ensure_loaded(THREAD)
        self.session.rpc.assert_called_once_with('thread/resume', dict(threadId=THREAD, excludeTurns=True))

    def test_approval_preserves_original_rpc_id(self):
        s = self.session
        s.notify(dict(id=42, method='item/commandExecution/requestApproval', params=dict(threadId=THREAD, command='ls')))
        token = next(iter(s.approvals))
        s.handle(dict(op='answer', thread=THREAD, approval=token, decision='decline'))
        s.connection.write.assert_called_once_with(dict(id=42, result=dict(decision='decline')))
        self.assertFalse(s.approvals)

    def test_question_requires_every_answer(self):
        s = self.session
        s.notify(dict(id='q', method='item/tool/requestUserInput', params=dict(threadId=THREAD, questions=[dict(id='one'), dict(id='two')])) )
        token = next(iter(s.approvals))
        req = dict(op='answer', thread=THREAD, approval=token, answers=json.dumps({'one': {'answers': ['yes']}}))
        with self.assertRaises(RPCError):
            s.handle(req)
        req['answers'] = json.dumps({'one': {'answers': ['yes']}, 'two': {'answers': ['free text']}})
        s.handle(req)
        self.assertEqual(s.connection.write.call_args.args[0]['result']['answers']['two']['answers'], ['free text'])

    def test_relative_image_is_project_relative(self):
        self.session.cwd[THREAD] = '/home/user/project'
        ref = self.session.asset(THREAD, 'images/chart.png')
        self.assertEqual(self.session.assets[(THREAD, ref['id'])], '/home/user/project/images/chart.png')

    def test_image_cannot_be_read_under_another_thread(self):
        ref = self.session.asset(THREAD, '/tmp/chart.png')
        with self.assertRaises(RPCError):
            self.session.handle(dict(op='image', thread=str(uuid.uuid4()), asset=ref['id']))

    def test_upload_offsets_and_image_signature(self):
        import runtime
        with tempfile.TemporaryDirectory() as directory, patch.object(runtime, 'STATE', Path(directory)):
            token = self.session.handle(dict(op='upload_prepare'))['token']
            chunk = base64.b64encode(b'not an image').decode()
            self.session.handle(dict(op='upload_chunk', token=token, data=chunk, offset='0'))
            with self.assertRaises(RPCError):
                self.session.handle(dict(op='upload_chunk', token=token, data=chunk, offset='0'))
            with self.assertRaises(RPCError):
                validate_image(Path(directory) / 'uploads' / (token + '.jpg'))


class TransportTests(unittest.TestCase):
    def test_real_child_process_notifications_and_server_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'fake.py'
            fake.write_text('''import json, sys
for line in sys.stdin:
 r=json.loads(line)
 if r.get('method')=='initialize':
  print(json.dumps({'id':r['id'],'result':{}}),flush=True)
 elif r.get('method')=='model/list':
  print(json.dumps({'method':'turn/started','params':{'threadId':'test','turn':{'id':'turn'}}}),flush=True)
  print(json.dumps({'id':99,'method':'item/commandExecution/requestApproval','params':{'threadId':'test'}}),flush=True)
  print(json.dumps({'id':r['id'],'result':{'data':[]}}),flush=True)
''')
            events = []
            connection = RPCConnection([sys.executable, str(fake)], events.append)
            try:
                self.assertEqual(connection.request('model/list', {}), {'data': []})
                self.assertEqual(len(events), 2)
                self.assertEqual(events[-1]['id'], 99)
            finally:
                connection.close()


if __name__ == '__main__':
    unittest.main()
