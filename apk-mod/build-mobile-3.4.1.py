"""Rebuild v3.4.1 mobile from the isolated patched worktree, without logging secrets.
Set A2A_KEYSTORE and A2A_KEYSTORE_PASS_FILE to use the existing release signer.
No key is generated. Without a key, produces an explicitly unsigned release APK.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
ROOT = BASE / 'upgrade-3.4.1'
EVIDENCE = ROOT / 'upgrade-evidence/mobile'
EXPECTED = 'd0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f'
p = argparse.ArgumentParser()
p.add_argument('--worktree', type=Path, default=BASE / 'mobile-build-3.4.1')
p.add_argument('--skip-web', action='store_true')
a = p.parse_args()
mobile = a.worktree / 'desktop-tauri/mobile'
android = mobile / 'android'
head = subprocess.check_output(['git', '-C', str(a.worktree), 'rev-parse', 'HEAD'], text=True).strip()
if head != '3ff4b8215d0d65c3451ca74923e90964ed7dbf59':
    raise SystemExit('Worktree must be based on exact upstream v3.4.1 commit')
node = Path(os.environ.get('NODE_BINARY', 'E:/AI/tools/node/node.exe'))
sdk = Path(os.environ.get('ANDROID_SDK_ROOT', 'E:/AI/tools/android-sdk'))
java = Path(os.environ.get('A2A_JAVA_HOME', 'E:/AI/tools/jdk21/jdk-21.0.12.1+1'))
env = os.environ.copy()
env.update({'PATH': str(node.parent) + os.pathsep + str(java / 'bin') + os.pathsep + env['PATH'], 'JAVA_HOME': str(java), 'ANDROID_HOME': str(sdk), 'ANDROID_SDK_ROOT': str(sdk), 'GRADLE_USER_HOME': 'E:/AI/tmp/gradle-home', 'ANDROID_USER_HOME': 'E:/AI/tmp/android-home', 'TEMP': 'E:/AI/tmp', 'TMP': 'E:/AI/tmp', 'npm_config_cache': 'E:/AI/tmp/npm-cache'})
EVIDENCE.mkdir(parents=True, exist_ok=True)
def run(name, command, cwd):
    log_path = EVIDENCE / (name + '.log')
    if log_path.exists(): log_path.read_bytes()
    with log_path.open('w', encoding='utf-8') as log:
        result = subprocess.run([str(x) for x in command], cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
    print(name + ': exit ' + str(result.returncode), flush=True)
    if result.returncode: raise SystemExit(result.returncode)

if not a.skip_web:
    npm = [node, node.parent / 'node_modules/npm/bin/npm-cli.js']
    run('npm-mobile-ci', npm + ['ci', '--no-audit', '--no-fund'], mobile)
    run('npm-ui-kit-ci', npm + ['ci', '--no-audit', '--no-fund'], mobile.parent / 'ui-kit')
    run('build-native', npm + ['run', 'build:native'], mobile)
    run('cap-sync', [node, mobile / 'node_modules/@capacitor/cli/bin/capacitor', 'sync', 'android'], mobile)

signed = bool(env.get('A2A_KEYSTORE') and env.get('A2A_KEYSTORE_PASS_FILE'))
if signed:
    cert = subprocess.check_output([str(java / 'bin/keytool.exe'), '-J-Duser.language=en', '-list', '-v', '-keystore', env['A2A_KEYSTORE'], '-storepass:file', env['A2A_KEYSTORE_PASS_FILE']], env=env, text=True, stderr=subprocess.STDOUT)
    fingerprints = [x.replace(':', '').lower() for x in re.findall(r'SHA256:\s*([A-Fa-f0-9:]+)', cert)]
    if fingerprints != [EXPECTED]: raise SystemExit('Existing signer does not match the pinned release certificate')
    env['A2A_KEY_ALIAS'] = env.get('A2A_KEY_ALIAS', 'a2a')
# Upstream release guard checks for this file; it contains no credentials.
props = android / 'keystore.properties'
if props.exists(): raise SystemExit('Refusing to replace an existing keystore.properties')
init = EVIDENCE / 'release-build.init.gradle'
init_text = '''gradle.beforeProject { project ->
    project.pluginManager.withPlugin('com.android.application') {
        project.androidComponents.finalizeDsl { android ->
            if (System.getenv('A2A_KEYSTORE') && System.getenv('A2A_KEYSTORE_PASS_FILE')) {
                def config = android.signingConfigs.release
                config.storeFile = new File(System.getenv('A2A_KEYSTORE'))
                config.keyAlias = System.getenv('A2A_KEY_ALIAS') ?: 'a2a'
                def password = new File(System.getenv('A2A_KEYSTORE_PASS_FILE')).getText('UTF-8').trim()
                config.storePassword = password
                config.keyPassword = password
            } else {
                android.buildTypes.release.signingConfig = null
            }
        }
    }
}
'''
if init.exists(): init.read_bytes()
init.write_text(init_text, encoding='utf-8')
props.write_text('# No secrets: release signing is injected in memory by the init script.\n', encoding='ascii')
try:
    run('gradle-release', ['cmd.exe', '/d', '/c', 'gradlew.bat', '--no-daemon', '--offline', '--stacktrace', '--console=plain', '-Dorg.gradle.java.home=' + java.as_posix(), '-I', init, '-PdevAppIdSuffix=.mod', 'assembleRelease'], android)
finally:
    props.unlink()
outputs = list((android / 'app/build/outputs/apk/release').glob('*.apk'))
if len(outputs) != 1: raise SystemExit('Expected exactly one release APK: ' + str(len(outputs)))
dest = EVIDENCE / ('Agent2API-3.4.1-mod' + ('' if signed else '-unsigned') + '.apk')
if dest.exists(): dest.read_bytes()
shutil.copyfile(outputs[0], dest)
if signed:
    run('apk-signature', ['cmd.exe', '/d', '/c', sdk / 'build-tools/36.0.0/apksigner.bat', 'verify', '--verbose', '--print-certs', dest], android)
run('apk-badging', [sdk / 'build-tools/36.0.0/aapt2.exe', 'dump', 'badging', dest], android)
badging = (EVIDENCE / 'apk-badging.log').read_text(encoding='utf-8')
package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
if not package or package.groups() != ('com.agent2api.mobile.mod', '30401', '3.4.1'):
    raise SystemExit('APK metadata differs from expected 3.4.1 mod release')
if signed and ('certificate SHA-256 digest: ' + EXPECTED) not in (EVIDENCE / 'apk-signature.log').read_text():
    raise SystemExit('Built APK signer differs from expected release certificate')
manifest = {'upstream_commit': '3ff4b8215d0d65c3451ca74923e90964ed7dbf59', 'apk': dest.name, 'bytes': dest.stat().st_size, 'sha256': hashlib.sha256(dest.read_bytes()).hexdigest(), 'signed': signed, 'certificate_sha256': EXPECTED if signed else None, 'applicationId': package[1], 'versionName': package[3], 'versionCode': int(package[2])}
manifest_path = EVIDENCE / 'apk-manifest.json'
if manifest_path.exists(): manifest_path.read_bytes()
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(json.dumps(manifest, indent=2))
