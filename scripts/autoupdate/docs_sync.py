"""Deterministic README/update.json rendering for the trusted publish job.

These files are derived from the signed plan and candidate module.prop, never
from upstream text. Keeping the rendering here lets bundle.py's allowlist stay
limited to payload/source snapshots while the human-facing entry points stop
pointing at an older release.
"""
import json
from pathlib import Path
import re

BEGIN = '<!-- AUTO-LATEST-BEGIN -->'
END = '<!-- AUTO-LATEST-END -->'


def _base(repo):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Invalid repository slug')
    return 'https://github.com/' + repo + '/releases'


def latest_block(plan, repo):
    ver = plan['version']
    rev = plan['module_revision']
    tag = f'v{ver}-magisk.{rev}'
    module = f'agent2api-magisk-v{ver}-magisk.{rev}-arm64.zip'
    apk = f'Agent2API-{ver}-mod.apk'
    base = _base(repo)
    return '\n'.join([
        BEGIN,
        f'## 最新版本：v{ver} / magisk.{rev}',
        '',
        f"自动同步上游 `{plan['tag']}`，精确源码 `{plan['commit']}`。",
        '',
        f'- **[下载 Magisk / KernelSU 模块 v{ver} · magisk.{rev}]({base}/tag/{tag})**：`{module}`。',
        f'- **[下载手机端 APK {ver}-mod]({base}/tag/apk-v{ver}-mod)**：`{apk}`，包名 `com.agent2api.mobile.mod`，版本 `{ver} / {plan["mobile_version_code"]}`。',
        '- 校验清单、构建来源与验收证据随模块 Release 附带；历史版本的手工验收报告仍保留在 [docs/](docs/)。',
        '- 模块内更新只替换服务端与面板；仓库公开后，手机端 APK 可在设备上运行 `a2a apk-update` 下载、校验并覆盖安装。',
        END,
        '',
    ])


def rewrite_readme(root, plan, repo):
    path = Path(root) / 'README.md'
    text = path.read_text(encoding='utf-8')
    start = text.find(BEGIN)
    marker = text.find(END)
    if start < 0 or marker < start:
        raise ValueError('README auto-latest markers missing')
    end = text.find('\n', marker)
    end = len(text) if end < 0 else end + 1
    updated = text[:start] + latest_block(plan, repo) + text[end:]
    if updated == text:
        return False
    path.write_text(updated, encoding='utf-8')
    return True


def update_json(plan, repo, module_prop, zip_sha256):
    version = re.search(r'^version=(.+)$', module_prop, re.M)
    code = re.search(r'^versionCode=([0-9]+)$', module_prop, re.M)
    if not version or not code:
        raise ValueError('Candidate module.prop lacks version metadata')
    if not re.fullmatch(r'[0-9a-f]{64}', zip_sha256):
        raise ValueError('Invalid module zip SHA-256')
    ver = plan['version']
    rev = plan['module_revision']
    tag = f'v{ver}-magisk.{rev}'
    module = f'agent2api-magisk-v{ver}-magisk.{rev}-arm64.zip'
    base = _base(repo)
    return {
        'version': version.group(1),
        'versionCode': int(code.group(1)),
        'zipUrl': f'{base}/download/{tag}/{module}',
        'changelog': f'{base}/tag/{tag}',
        'sha256': zip_sha256,
    }


def sync(root, plan, repo, zip_sha256):
    """Render derived entry points; return relative paths actually changed."""
    root = Path(root)
    # Validate every derived value before the first write.
    document = update_json(plan, repo, (root / 'module/module.prop').read_text(encoding='utf-8'), zip_sha256)
    changed = []
    if rewrite_readme(root, plan, repo):
        changed.append('README.md')
    text = json.dumps(document, indent=2, ensure_ascii=False) + '\n'
    path = root / 'update.json'
    if not path.exists() or path.read_text(encoding='utf-8') != text:
        path.write_text(text, encoding='utf-8')
        changed.append('update.json')
    return changed
