"""Display policy derived from public Codex TUI item types; never changes stored history."""
import hashlib
import json
import re

IMAGE_LINK = re.compile(r'!\[([^\]]*)\]\(([^\s)]+)(?:\s+"[^"]*")?\)')


def compact(value, limit=12000):
    if isinstance(value, str):
        return value[:limit]
    return json.dumps(value, ensure_ascii=False, indent=2)[:limit]


def present(item, turn_id='', register_asset=None):
    kind = item.get('type', 'unknown')
    ident = str(item.get('id', hashlib.sha256(compact(item).encode()).hexdigest()[:20]))
    result = dict(id=ident, kind=kind, turnID=turn_id, role='activity', title='', text='',
                  detail='', images=[], importance='collapsed', status=item.get('status', 'completed'))

    def image(source):
        if not isinstance(source, str) or not source:
            return
        if source.startswith(('https://', 'http://')) or (source.startswith('data:image/') and not register_asset):
            ref = dict(id=hashlib.sha256(source.encode()).hexdigest(), source=source, local=False)
        elif register_asset:
            ref = register_asset(source)
        else:
            return
        result['images'].append(ref)

    if kind == 'userMessage':
        result.update(role='user', title='你', importance='visible')
        parts = []
        for content in item.get('content', []):
            if content.get('type') == 'text':
                parts.append(content.get('text', ''))
            elif content.get('type') == 'image':
                image(content.get('url'))
            elif content.get('type') == 'localImage':
                image(content.get('path'))
        result['text'] = '\n'.join(parts)
    elif kind == 'agentMessage':
        result.update(role='assistant', title='Codex', text=item.get('text', ''), importance='visible')
        if item.get('questions'):
            result['questions'] = item['questions']
        elif item.get('phase') == 'commentary' and '```' not in result['text']:
            result.update(importance='collapsed', title='进度说明')
    elif kind == 'reasoning':
        # Only summaries that Codex exposes. Do not attempt to recover hidden reasoning.
        result.update(title='思考摘要', text='\n'.join(item.get('summary', [])))
    elif kind == 'plan':
        result.update(title='计划', text=item.get('text', ''), importance='visible')
    elif kind == 'commandExecution':
        result.update(title=item.get('command', '执行命令'), text=item.get('aggregatedOutput') or '',
                      detail=compact({k: item[k] for k in ('cwd', 'exitCode', 'durationMs') if k in item}))
        if item.get('exitCode') not in (None, 0) or item.get('status') in ('failed', 'declined'):
            result.update(importance='attention', title='命令执行失败 · ' + result['title'])
    elif kind == 'fileChange':
        changes = item.get('changes', [])
        result.update(title=f'修改了 {len(changes)} 个文件', text=compact(changes), importance='visible')
    elif kind in ('mcpToolCall', 'dynamicToolCall'):
        result.update(title=str(item.get('tool', item.get('toolName', '工具调用'))),
                      text=compact(item.get('result', item.get('contentItems', ''))))
        if item.get('error') or item.get('success') is False or item.get('status') == 'failed':
            result.update(importance='attention', detail=compact(item.get('error', '工具执行失败')))
        def find_images(value):
            if isinstance(value, dict):
                if value.get('type') == 'image' and value.get('data'):
                    image('data:' + value.get('mimeType', 'image/png') + ';base64,' + value['data'])
                for child in value.values():
                    find_images(child)
            elif isinstance(value, list):
                for child in value:
                    find_images(child)
        find_images(item.get('result', {}))
        if result['images']:
            result['importance'] = 'visible'
    elif kind in ('imageGeneration', 'imageView'):
        result.update(title='图片', importance='visible')
        for key in ('path', 'imagePath', 'savedPath', 'result', 'url'):
            image(item.get(key))
    elif kind in ('error', 'warning'):
        result.update(title='需要注意', text=compact(item.get('message', item)), importance='attention')
    elif kind == 'contextCompaction':
        result.update(title='上下文已压缩', text='较早的上下文已由 Codex 整理。完整记录仍可按页查看。')
    else:
        # Unknown item types remain accessible rather than silently disappearing.
        result.update(title=kind, text=compact(item))
    for match in IMAGE_LINK.finditer(result['text']):
        image(match.group(2))
    result['text'] = IMAGE_LINK.sub(lambda m: m.group(1), result['text'])
    if result['status'] in ('failed', 'declined') or item.get('failure'):
        result['importance'] = 'attention'
    if result['status'] in ('inProgress', 'running'):
        result['importance'] = 'visible'
    return result
