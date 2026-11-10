"""Use the current release for a no-publish end-to-end build rehearsal."""
import json
import os
from pathlib import Path
from control import ROOT, detect, dump, version
config = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())
current = config['last_version']
# A pinned prerelease must be rehearsed as a prerelease, or detection never finds it.
allow = '-' in current
config['last_version'] = '0.0.0'
plan = detect(config, os.getenv('UPSTREAM_TOKEN') or os.getenv('GH_TOKEN'), allow_prerelease=allow)
if version(plan['version']) != version(current):
    raise ValueError('New upstream release exists: run normal sync instead of current-version smoke')
plan['smoke'] = True
plan['mobile_version_code'] = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())['mobile_version_code']
dump('automation-out/plan.json', plan)
