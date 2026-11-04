"""Sign only an already-built APK on a clean trusted runner; never run upstream Gradle here."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

EXPECTED = 'd0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f'

def run(args):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.STDOUT, text=True)

def validate_apk(apk, aapt, version, code):
    text = run([aapt, 'dump', 'badging', apk])
    match = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", text)
    if not match or match.groups() != ('com.agent2api.mobile.mod', str(code), version):
        raise ValueError('APK applicationId/version identity differs from plan')
    with zipfile.ZipFile(apk) as z:
        if z.testzip() is not None or len(z.namelist()) != len(set(z.namelist())):
            raise ValueError('APK ZIP integrity failure')
        return {i.filename: hashlib.sha256(z.read(i)).hexdigest() for i in z.infolist() if i.filename.startswith('assets/public/') and not i.is_dir()}

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--plan', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    plan = json.loads(a.plan.read_text())
    tools = Path(os.environ['ANDROID_HOME'])/'build-tools/36.0.0'
    signer, align, aapt = [tools/x for x in ('apksigner', 'zipalign', 'aapt2')]
    assets = validate_apk(a.input, aapt, plan['version'], plan['mobile_version_code'])
    if not assets:
        raise ValueError('APK lacks Capacitor Web assets')
    a.output.mkdir(parents=True, exist_ok=True)
    dest = a.output/f"Agent2API-{plan['version']}-mod.apk"
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        key = d/'release.jks'
        key.write_bytes(base64.b64decode(os.environ['ANDROID_KEYSTORE_BASE64'], validate=True))
        key.chmod(0o600)
        aligned = d/'aligned.apk'
        subprocess.run([str(align), '-f', '-p', '4', str(a.input), str(aligned)], check=True)
        # apksigner reads passwords from environment, never argv or a file.
        subprocess.run([str(signer), 'sign', '--ks', str(key), '--ks-key-alias', os.environ['ANDROID_KEY_ALIAS'], '--ks-pass', 'env:ANDROID_KEYSTORE_PASSWORD', '--key-pass', 'env:ANDROID_KEY_PASSWORD', '--out', str(dest), str(aligned)], check=True)
        result = run([signer, 'verify', '--verbose', '--print-certs', dest])
        fingerprints = re.findall(r'certificate SHA-256 digest: ([0-9a-f]+)', result)
        if fingerprints != [EXPECTED] or 'Verified using v2 scheme (APK Signature Scheme v2): true' not in result:
            raise ValueError('Signed APK certificate or v2 verification differs from pinned signer')
    if assets != validate_apk(dest, aapt, plan['version'], plan['mobile_version_code']):
        raise ValueError('APK assets changed while signing')
    (a.output/'signature.json').write_text(json.dumps({'certificate_sha256': EXPECTED, 'sha256': hashlib.sha256(dest.read_bytes()).hexdigest(), 'apk': dest.name, 'version': plan['version'], 'version_code': plan['mobile_version_code'], 'assets_verified': len(assets)}, indent=2)+'\n')
    print('Signed APK verified:', dest.name, EXPECTED)

if __name__ == '__main__':
    main()
