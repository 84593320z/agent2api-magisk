"""Rebuild the current upstream version as one new module revision.

Used when this repository is fixed but upstream has not released anything new:
the upstream version and Android versionCode stay pinned, one fresh
`magisk.<n>` release carries the module and any reviewed mobile changes,
and publishing verifies both Release tracks before moving update.json.
"""
import json
import os
from pathlib import Path
from control import ROOT, dump


def build_plan(config, run_id=''):
    """Derive the next-revision plan from the recorded checkpoint."""
    previous = config.get('last_plan')
    if not previous:
        raise ValueError('config has no last_plan; run a normal upstream sync first')
    plan = dict(previous)
    plan.pop('retry', None)
    plan['changed'] = True
    plan['republish'] = True
    plan['smoke'] = False
    plan['module_revision'] = config['module_revision'] + 1
    plan['mobile_version_code'] = config['mobile_version_code']
    plan['run_id'] = run_id
    return plan


def pending(plan_path):
    """True when detection already produced real upstream work to publish."""
    path = Path(plan_path)
    if not path.exists():
        return False
    detected = json.loads(path.read_text(encoding='utf-8'))
    return bool(detected.get('changed') or detected.get('retry'))


def main(plan_path='automation-out/plan.json'):
    if pending(plan_path):
        print('upstream already has pending work; leaving the normal sync plan in place')
        return 1
    config = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())
    plan = build_plan(config, os.getenv('GITHUB_RUN_ID', ''))
    dump(plan_path, plan)
    print(json.dumps(plan))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
