"""Prove that the delivered APK embeds the freshly built Web assets and plugins."""
from pathlib import Path
import hashlib, json, zipfile
BASE = Path(__file__).resolve().parents[2]
ROOT = BASE / 'upgrade-3.4.1'
OUT = ROOT / 'upgrade-evidence/mobile'
APK = OUT / 'Agent2API-3.4.1-mod.apk'
WEB = BASE / 'mobile-build-3.4.1/desktop-tauri/mobile/android-www'
results = []
with zipfile.ZipFile(APK) as archive:
    for path in sorted(WEB.rglob('*')):
        if not path.is_file(): continue
        rel = path.relative_to(WEB).as_posix()
        embedded = archive.read('assets/public/' + rel)
        actual = path.read_bytes()
        if embedded != actual: raise SystemExit('APK Web asset mismatch: ' + rel)
        results.append({'asset': rel, 'bytes': len(embedded), 'sha256': hashlib.sha256(embedded).hexdigest()})
    plugins = json.loads(archive.read('assets/capacitor.plugins.json'))
    ids = [p['pkg'] for p in plugins]
    if not {'@capacitor/app', '@capacitor/keyboard'}.issubset(ids):
        raise SystemExit('Expected Capacitor native plugins missing')
    report = {'apk_sha256': hashlib.sha256(APK.read_bytes()).hexdigest(), 'all_web_assets_match': True, 'assets': results, 'native_plugins': plugins}
    arsc = archive.getinfo('resources.arsc')
    report['resources_arsc_stored'] = arsc.compress_type == zipfile.ZIP_STORED
    if not report['resources_arsc_stored']: raise SystemExit('resources.arsc is compressed')
path = OUT / 'apk-assets-verification.json'
if path.exists(): path.read_bytes()
path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(f'PASS {len(results)} APK Web assets match build; native plugins {ids}; resources.arsc STORED')
