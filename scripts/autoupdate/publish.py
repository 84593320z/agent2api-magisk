"""Idempotent trusted publishing and failure PRs. No build subprocess receives a token."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request
from control import dump, request, version, release_refs
from bundle import ROOT, apply, checkpoint_plan
from docs_sync import sync as sync_docs

REPO = '84593320z/agent2api-magisk'
BASE = 'https://api.github.com/repos/' + REPO
TOKEN = os.environ.get('GH_TOKEN')

def api(path, method='GET', data=None):
    return request(BASE+path, TOKEN, data, method)

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()

def stage_file(name):
    data = (ROOT/name).read_bytes()
    if re.search(rb'(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)', data):
        raise ValueError('Secret-shaped candidate content')
    mode = '100644'
    old = git('ls-files', '-s', '--', name).split()
    if old:
        mode = old[0]
    blob = git('hash-object', '-w', '--no-filters', '--', name)
    git('update-index', '--add', '--cacheinfo', mode, blob, name)


def commit_candidate(plan, archive, expected, branch='main'):
    if git('rev-parse', 'HEAD') != expected or git('status', '--porcelain'):
        raise ValueError('Trusted checkout differs from expected clean baseline')
    if api('/git/ref/heads/main')['object']['sha'] != expected:
        raise ValueError('main advanced; rerun against current baseline')
    rows = apply(archive, plan=plan)
    config = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())
    if config['last_version'] != plan['version'] or config['last_commit'] != plan['commit']:
        raise ValueError('Candidate provenance/config mismatch')
    for row in rows:
        name = row['path']
        if row['deleted']:
            git('update-index', '--remove', '--', name)
        else:
            stage_file(name)
    git('-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
        'commit', '-m', (f"chore: rebuild module {plan['version']} (magisk.{plan['module_revision']})"
                         if plan.get('republish') else
                         f"chore: sync upstream {plan['tag']} (magisk.{plan['module_revision']})"))
    commit = git('rev-parse', 'HEAD')
    subprocess.run(['git', '-C', str(ROOT), 'push', 'origin', 'HEAD:refs/heads/'+branch], check=True)
    return commit


def commit_docs(plan, zip_sha256, branch='main'):
    """Point update.json/README at a Release only after both Release tracks exist.

    A retry deliberately starts at the persisted checkpoint, while main may
    already contain a reviewed publisher fix.  Catch up by fast-forward only;
    never commit documentation on top of the old checkpoint or force-push main.
    """
    head = git('rev-parse', 'HEAD')
    remote = api('/git/ref/heads/main')['object']['sha']
    if git('status', '--porcelain'):
        raise ValueError('Documentation checkout is not clean')
    if remote != head:
        git('fetch', '--no-tags', 'origin', 'main')
        git('merge-base', '--is-ancestor', head, remote)
        git('checkout', '--detach', remote)
        head = remote
    config = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())
    if config.get('last_plan') != checkpoint_plan(plan):
        raise ValueError('Documentation checkpoint differs from published plan')
    names = sync_docs(ROOT, plan, config['repository'], zip_sha256)
    if not names:
        print('Update entry points already current:', head)
        return head
    for name in names:
        stage_file(name)
    git('-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
        'commit', '-m', f"docs: publish module {plan['version']} (magisk.{plan['module_revision']})")
    commit = git('rev-parse', 'HEAD')
    subprocess.run(['git', '-C', str(ROOT), 'push', 'origin', 'HEAD:refs/heads/'+branch], check=True)
    return commit

def recovery_commit(plan):
    """Recover the original checkpoint, even when main acquired later commits."""
    canonical = checkpoint_plan(plan)
    head = git('rev-parse', 'HEAD')
    remote = api('/git/ref/heads/main')['object']['sha']
    if remote != head:
        # Retry jobs check out the original baseline to reuse its signed
        # artifacts.  Later publisher fixes on main are valid only when they
        # descend from that baseline; divergent/rewritten history is rejected.
        if git('status', '--porcelain'):
            raise ValueError('Recovery checkout is not clean')
        git('fetch', '--no-tags', 'origin', 'main')
        git('merge-base', '--is-ancestor', head, remote)
    # Checkout is deliberately shallow in Actions; materialize main history locally.
    if git('rev-parse', '--is-shallow-repository') == 'true':
        git('fetch', '--unshallow', 'origin', 'main')
    refs = release_refs(REPO, plan, TOKEN)
    def config_at(commit):
        return json.loads(git('show', commit + ':scripts/autoupdate/config.json'))
    def matches(cfg):
        return (cfg.get('last_plan') == canonical and cfg.get('last_version') == canonical['version']
                and cfg.get('last_commit') == canonical['commit']
                and cfg.get('module_revision') == canonical['module_revision']
                and cfg.get('mobile_version_code') == canonical['mobile_version_code'])
    # A maintenance retry can see only the old, same-version APK tag.  It is not
    # this plan's checkpoint; keep looking instead of rejecting the persisted
    # module checkpoint or accidentally recovering the old APK commit.
    for commit in dict.fromkeys(refs.values()):
        # This command must succeed: an unrelated or rewritten tag is never reused.
        git('merge-base', '--is-ancestor', commit, head)
        if matches(config_at(commit)):
            return commit
    # Oldest matching main commit is the first persisted checkpoint, not latest HEAD.
    for commit in git('rev-list', '--reverse', '--first-parent', head).splitlines():
        try:
            cfg = config_at(commit)
        except (subprocess.CalledProcessError, ValueError):
            continue
        if matches(cfg):
            git('merge-base', '--is-ancestor', commit, head)
            return commit
    raise ValueError('Persisted checkpoint commit not found in main history')


def download_asset(asset):
    return request(asset['url'], TOKEN, binary=True)


def get_release(tag):
    return next((x for x in api('/releases?per_page=100') if x['tag_name'] == tag), None)


def release_assets_identical(tag, files):
    """Compare signed output with the published track, not the baseline Git diff.

    Overlay fixes may already be in the baseline commit, so the candidate
    manifest says nothing about whether the existing Release still matches.
    """
    r = get_release(tag)
    if r is None:
        return False
    expected = {p.name: p for p in files}
    assets = r.get('assets', [])
    old = {x['name']: x for x in assets}
    if len(old) != len(assets) or set(old) - set(expected):
        raise ValueError('Unexpected existing assets; preserving release: '+tag)
    if set(old) != set(expected):
        return False
    for name, path in expected.items():
        data = path.read_bytes()
        asset = old[name]
        if (asset['size'] != len(data)
                or hashlib.sha256(download_asset(asset)).hexdigest() != hashlib.sha256(data).hexdigest()):
            return False
    return True


def upload_asset(r, p, data):
    url = r['upload_url'].split('{')[0]+'?name='+urllib.parse.quote(p.name)
    headers = {'Authorization':'Bearer '+TOKEN,'Accept':'application/vnd.github+json','Content-Type':'application/octet-stream','User-Agent':'agent2api-autoupdate'}
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method='POST'), timeout=180) as response:
        return json.load(response)


def release(tag, commit, files, body, prerelease=False, move_tag=False, replace_assets=False):
    if move_tag and not replace_assets:
        raise ValueError('Moving a release tag requires explicit asset replacement mode')
    refs = api('/git/matching-refs/tags/'+tag)
    found = next((r for r in refs if r['ref']=='refs/tags/'+tag), None)
    if found is None:
        api('/git/refs', 'POST', {'ref':'refs/tags/'+tag,'sha':commit})
    elif found['object']['type'] != 'commit':
        raise ValueError('Existing release tag is not a commit')
    elif found['object']['sha'] != commit and not move_tag:
        raise ValueError('Existing release tag points elsewhere')
    r = get_release(tag)
    if r is None:
        r = api('/releases', 'POST', {'tag_name':tag,'target_commitish':commit,'name':'Agent2API '+tag,'body':body,'draft':True,'prerelease':prerelease})
    old = {x['name']:x for x in r['assets']}
    if set(old)-{x.name for x in files}:
        raise ValueError('Unexpected existing assets; preserving release')
    for p in files:
        data = p.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        asset = old.get(p.name)
        if asset is not None:
            same = (asset['size'] == len(data)
                    and hashlib.sha256(download_asset(asset)).hexdigest() == digest)
            if not same:
                if not replace_assets:
                    raise ValueError('Release download hash differs: '+p.name)
                api('/releases/assets/'+str(asset['id']), 'DELETE')
                asset = None
        if asset is None:
            asset = upload_asset(r, p, data)
        if asset['size'] != len(data) or hashlib.sha256(download_asset(asset)).hexdigest() != digest:
            raise ValueError('Release download hash differs: '+p.name)
    # Move a mutable same-version APK tag only after every downloaded asset is verified.
    if found is not None and found['object']['sha'] != commit:
        api('/git/refs/tags/'+tag, 'PATCH', {'sha':commit, 'force':True})
    if r['draft'] or replace_assets:
        r = api('/releases/'+str(r['id']), 'PATCH', {'draft':False,'body':body,'prerelease':bool(prerelease),'make_latest':'false' if prerelease else 'true'})
    print('Verified release:', r['html_url'])
    return r['html_url']


def is_republish(cfg, plan):
    """True for a same-upstream maintenance rebuild, one new module revision."""
    return (bool(plan.get('republish')) and cfg['last_version'] == plan['version']
            and plan['module_revision'] == cfg['module_revision'] + 1)


def publish(a):
    plan = json.loads(a.plan.read_text())
    # Validate signed artifact metadata and all binaries before pushing any source.
    sig = json.loads((a.artifacts/'signature.json').read_text())
    expected_cert = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())['certificate_sha256']
    apk = a.artifacts/f"Agent2API-{plan['version']}-mod.apk"
    module = a.artifacts/f"agent2api-magisk-v{plan['version']}-magisk.{plan['module_revision']}-arm64.zip"
    assert sig['certificate_sha256']==expected_cert and sig['version']==plan['version'] and sig['sha256']==hashlib.sha256(apk.read_bytes()).hexdigest()
    assert module.stat().st_size > 1000000
    files = [module, apk, a.artifacts/'signature.json', a.artifacts/'plan.json']
    for name in ('provenance.json', 'elf-compatibility.json', 'mobile-build.json', 'full-regression.txt'):
        path = a.artifacts/name
        if not path.is_file():
            raise ValueError('Required acceptance evidence missing: '+name)
        files.append(path)
    if '=== 全部通过 ===' not in (a.artifacts/'full-regression.txt').read_text(encoding='utf-8'):
        raise ValueError('Regression acceptance marker missing')
    if json.loads((a.artifacts/'elf-compatibility.json').read_text()).get('status') != 'PASS':
        raise ValueError('ELF acceptance not PASS')
    cfg = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())
    maintenance = bool(plan.get('republish'))
    republish = is_republish(cfg, plan)
    sums = a.artifacts/'SHA256SUMS.txt'
    sums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files), encoding='utf-8')
    apk_sums = a.artifacts/'apk-checksums'/'SHA256SUMS.txt'
    apk_sums.parent.mkdir(parents=True, exist_ok=True)
    apk_files = [apk, a.artifacts/'signature.json', apk_sums]
    apk_sums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in apk_files[:2]), encoding='utf-8')
    apk_tag = f"apk-v{plan['version']}-mod"
    # The baseline may already contain an overlay repair.  Decide from the
    # actual signed assets before any checkpoint or Release is changed.
    apk_changed = maintenance and not release_assets_identical(apk_tag, apk_files)
    if cfg['last_version']==plan['version'] and not republish:
        assert cfg['last_commit']==plan['commit']
        commit = recovery_commit(plan)
    else:
        commit = commit_candidate(plan, a.artifacts/'candidate.zip', a.expected)
    body = f"自动同步上游 {plan['tag']}，精确源码 `{plan['commit']}`。\n\n模块保留 Android 启动桥接、事务恢复与 DNS 修复；手机端保留开关写屏障/严格回显。APK 使用既有 .mod 证书。完整离线回归、ELF闭包、资源与签名核验通过；CI 不替代真机验收。\n\n源码提交 `{commit}`。安装旧包 com.agent2api.mobile 的用户须按迁移文档重建配置；既有同签名 .mod 可覆盖升级。\n"
    prerelease = bool(plan.get('prerelease'))
    if prerelease:
        body += "\n※ 上游本次为预发布（beta）：模块与 APK 均按同一精确提交构建，签名与既有 .mod 证书一致；上游正式版发布后会自动再同步一版，届时可正常覆盖升级。\n"
    if maintenance:
        if apk_changed:
            body += f"\n※ 本次是同上游版本的维护重发：模块与 APK 资产均有更新，`{apk_tag}` 会在完整验签和回下载校验后受控替换；versionCode 与签名保持不变，可覆盖升级。\n"
        else:
            body += f"\n※ 本次是模块侧修复的重新构建：上游版本与 APK 资产未变，仅模块脚本更新；已逐字节核验 `{apk_tag}` 的既有 APK，手机端无需重装。\n"
    release(f"v{plan['version']}-magisk.{plan['module_revision']}", commit, files+[sums], body, prerelease)
    release(apk_tag, commit, apk_files, body, prerelease,
            move_tag=maintenance, replace_assets=maintenance)
    commit_docs(plan, hashlib.sha256(module.read_bytes()).hexdigest())

def failure(a):
    plan = json.loads(a.plan.read_text()) if a.plan.exists() else {'tag':'detection-failed'}
    tag = re.sub('[^A-Za-z0-9._-]', '-', plan['tag'])
    branch = 'automation/failure-'+tag
    # Reuse an existing failure branch rather than creating a divergent commit.
    refs = api('/git/matching-refs/heads/'+branch)
    if any(r['ref']=='refs/heads/'+branch for r in refs):
        git('fetch', 'origin', branch)
        git('checkout', '--detach', 'FETCH_HEAD')
    # Failure PRs contain only sanitized metadata, never untrusted candidate code or raw logs.
    path = ROOT/'docs/automation-failures'/f'{tag}.md'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"# 自动同步待处理：{tag}\n\n运行：{a.run_url}\n\n构建、测试、补丁、签名或发布检查失败；稳定 Release 保持。详细日志见 Actions 运行与 artifacts。此 PR 不合并候选载荷，不更改同步游标。\n", encoding='utf-8')
    git('add', '--', str(path.relative_to(ROOT)))
    if subprocess.run(['git','-C',str(ROOT),'diff','--cached','--quiet']).returncode:
        subprocess.run(['git','-C',str(ROOT),'-c','user.name=github-actions[bot]','-c','user.email=41898282+github-actions[bot]@users.noreply.github.com','commit','-m','ci: record failed upstream sync '+tag], check=True)
        subprocess.run(['git','-C',str(ROOT),'push','origin','HEAD:refs/heads/'+branch], check=True)
    prs = api('/pulls?state=open&head=84593320z:'+branch)
    if not prs:
        result = api('/pulls','POST',{'title':'自动同步待处理：'+tag,'head':branch,'base':'main','body':'运行日志：'+a.run_url+'\n\n自动构建/验证失败。此 PR 仅记录故障，稳定发布未覆盖。'})
        print('Failure PR:', result['html_url'])

def main():
    p = argparse.ArgumentParser()
    p.add_argument('command',choices=['publish','failure'])
    p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--artifacts',type=Path,default=Path('automation-out'))
    p.add_argument('--expected',default='')
    p.add_argument('--run-url',default='')
    a = p.parse_args()
    (publish if a.command=='publish' else failure)(a)
if __name__=='__main__':
    main()
