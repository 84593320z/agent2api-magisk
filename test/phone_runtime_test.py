#!/usr/bin/env python3
"""Read-only production-fragment regression; no ADB; isolated review scratch.

Run: re-python test/phone_runtime_test.py [--module PATH] [--sh SH]
Production sources are read but never sourced/executed wholesale. Destructive
commands in lifecycle tests are shell mocks; status output uses the exact current
production printf command with its output redirection removed for capture.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import atexit


def function(text, name):
    start = re.search(r"(?m)^" + re.escape(name) + r"\(\)\s*\{", text)
    if not start:
        raise AssertionError('missing function ' + name)
    # The awk program inside json_escape contains indented closing braces.
    # Use actual production shell-function terminators, not the first awk brace.
    terminator = r"(?m)^    \}[ \t]*$" if name == 'status_json_write' else r"(?m)^\}[ \t]*$"
    end = re.search(terminator, text[start.end():])
    if not end:
        raise AssertionError('missing function end ' + name)
    return text[start.start():start.end() + end.end()]


def quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def shell_path(path):
    value = str(path.resolve()).replace('\\', '/')
    if re.match(r'^[A-Za-z]:/', value):
        return '/' + value[0].lower() + value[2:]
    return value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--module', type=Path, default=Path(__file__).resolve().parents[1] / 'module')
    ap.add_argument('--sh', default=os.environ.get('A2A_SH') or shutil.which('sh'))
    ap.add_argument('--static-only', action='store_true', help='Do not start a shell when host shell startup is blocked')
    args = ap.parse_args()
    if not args.sh:
        raise SystemExit('sh executable missing; pass --sh')
    module = args.module.resolve()
    paths = {
        'common': module / 'libexec/common.sh',
        'supervise': module / 'libexec/supervise.sh',
        'fallback': module / 'META-INF/com/google/android/update-binary',
        'customize': module / 'customize.sh',
    }
    source = {key: path.read_text(encoding='utf-8') for key, path in paths.items()}
    outcomes = []
    scratch_root = Path(__file__).resolve().parents[2] / 'phone-fix-evidence/review'
    scratch_root.mkdir(parents=True, exist_ok=True)
    scratch = tempfile.TemporaryDirectory(prefix='phone-runtime-', dir=scratch_root)
    atexit.register(scratch.cleanup)
    scratch_path = Path(scratch.name)
    assignment_file = scratch_path / 'customize-assignments.sh'
    assignment_file.write_text('\n'.join(re.findall(r'(?m)^(?:APP_HOME|TMPD)=.*$', source['customize'])) + '\n', encoding='utf-8', newline='\n')
    shell_blocked = 'static-only requested; shell execution skipped' if args.static_only else None
    if not args.static_only:
        probe = subprocess.run([args.sh, '-c', 'printf shell-ready'], text=True,
                               encoding='utf-8', capture_output=True, timeout=20)
        if probe.returncode != 0:
            shell_blocked = 'shell startup rc=%s: %s' % (probe.returncode, probe.stderr.strip())

    def run(script, stdin=None):
        if shell_blocked:
            raise RuntimeError('HOST_BLOCKED: ' + shell_blocked)
        env = dict(os.environ, MSYS_NO_PATHCONV='1', MSYS2_ARG_CONV_EXCL='*')
        # A real LF script avoids Windows CreateProcess -c quote/backslash rewriting.
        script_file = scratch_path / 'case.sh'
        script_file.write_text(script + '\n', encoding='utf-8', newline='\n')
        result = subprocess.run([args.sh, shell_path(script_file)], input=stdin, text=True,
                                encoding='utf-8', capture_output=True, env=env, timeout=20)
        if result.returncode:
            raise AssertionError('shell rc=%s stderr=%s stdout=%s' %
                                 (result.returncode, result.stderr, result.stdout))
        if result.stderr:
            raise AssertionError('unexpected stderr: ' + result.stderr)
        return result.stdout

    def check(name, action):
        try:
            action()
            outcomes.append({'name': name, 'status': 'PASS'})
        except Exception as error:
            state = 'BLOCKED' if str(error).startswith('HOST_BLOCKED:') else 'FAIL'
            outcomes.append({'name': name, 'status': state, 'error': str(error)})

    layout = function(source['common'], 'ensure_layout')
    escape = function(source['supervise'], 'json_escape')
    status = function(source['supervise'], 'status_json_write')
    printf_lines = [line for line in status.splitlines() if line.strip().startswith("printf '%s\\n'")]
    printf_cmd = printf_lines[0].split(' >"$_tmp"', 1)[0] if printf_lines else ''

    def printf_test():
        assert printf_cmd and len(printf_lines) == 1, 'expected one production printf command'
        assert '<<EOF' not in status, 'status still has heredoc'
        for state in ('running', 'running-unverified', 'stopped'):
            script = escape + '\n' + '\n'.join([
                '_js_status=$(json_escape ' + quote(state) + ')',
                '_js_ver=$(json_escape ' + quote('v3.4.1 "quoted" \\ path\nsecond\tline') + ')',
                'CHILD=123; _up=91; RESTARTS=2; FAILS=0; PORT=3065; _pp=3066',
                'TMPDIR=/this/path/intentionally/does/not/exist',
                'export TMPDIR',
                'now_epoch() { printf 1793790000; }',
                printf_cmd,
            ])
            payload = json.loads(run(script))
            assert payload['status'] == state
            assert payload['version'] == 'v3.4.1 "quoted" \\ path\nsecond\tline'
            for key, value in {'server_pid': 123, 'uptime': 91, 'restarts': 2,
                               'fails': 0, 'port': 3065, 'panel_port': 3066,
                               'ts': 1793790000}.items():
                assert payload[key] == value, (key, payload)
            assert isinstance(payload['supervisor_pid'], int)

    check('production status printf: running/unverified/stopped, JSON escapes, invalid TMPDIR', printf_test)

    # Use an existing directory, mock chmod/live-link; all test operations read-only.
    runtime = shell_path(module)
    variables = ('APP_HOME PAYLOAD PLIB BINDIR CFGDIR DATADIR LOGDIR RUNDIR TMPD '
                 'HOMEDIR BACKUPDIR DLDIR A2A_LIVE').split()
    assignments = '\n'.join(key + '=' + quote(runtime) for key in variables)

    def layout_export():
        script = assignments + '\n' + layout + '\n' + '\n'.join([
            'chmod() { :; }; live_link_refresh() { :; }',
            'TMPDIR=/this/installer/cache/is/missing; export TMPDIR',
            'ensure_layout || exit 21',
            '[ "$TMPDIR" = "$TMPD" ] || exit 22',
            'sh -c \'[ "$TMPDIR" = "$1" ]\' sh "$TMPD" || exit 23',
            'printf exported',
        ])
        assert run(script) == 'exported'

    check('production ensure_layout replaces inherited TMPDIR and exports to child', layout_export)

    def layout_failed():
        script = assignments + '\n' + layout + '\n' + '\n'.join([
            'chmod() { :; }; live_link_refresh() { :; }; mkdir() { return 1; }',
            'TMPD=' + quote(shell_path(paths['common'])),
            'TMPDIR=/old/cache; export TMPDIR',
            'ensure_layout; rc=$?',
            '[ "$rc" = 1 ] && [ "$TMPDIR" = /old/cache ] || exit 24',
        ])
        run(script)

    check('production ensure_layout reports invalid TMPD instead of exporting it', layout_failed)

    def static_contracts():
        assert 'TMPDIR=$TMPD' in layout and 'export TMPDIR' in layout
        assert layout.index('[ -d "$TMPD" ] && [ -w "$TMPD" ]') < layout.index('export TMPDIR')
        assert '<<EOF' not in status and printf_cmd
        fb = source['fallback']
        assert 'export TMPDIR="$_A2A_INSTALL_TMP"' in fb
        assert 'rm -rf "$_A2A_INSTALL_TMP"' in fb
        assert not re.search(r'(?m)^rm -rf "\$TMPD"', fb)
        assert '_A2A_INSTALL_TMPIR' not in fb

    check('static production contracts: no heredoc, persistent TMPDIR, isolated fallback cleanup', static_contracts)

    fallback = source['fallback']
    tmp_decl = re.search(r'(?m)^(_A2A_INSTALL_TMP|TMPD)=/data/local/tmp/agent2api_install\.\$\$', fallback)
    export_line = re.search(r'(?m)^export TMPDIR=.*$', fallback)
    cleanup_lines = re.findall(r'(?m)^rm -rf "\$(?:_A2A_INSTALL_TMP|TMPD)"\s*$', fallback)
    customize_assignments = '\n'.join(re.findall(r'(?m)^(?:APP_HOME|TMPD)=.*$', source['customize']))

    def fallback_lifecycle():
        assert tmp_decl and export_line and cleanup_lines, 'missing fallback fragments'
        script = '\n'.join([
            tmp_decl.group(0),
            'expected_install="${_A2A_INSTALL_TMP:-$TMPD}"',
            export_line.group(0),
            '[ "$TMPDIR" = "$expected_install" ] || exit 25',
            # Source a real LF fixture containing only exact production assignments.
            '. ' + quote(shell_path(assignment_file)) + ' || exit 26',
            '[ "$TMPD" = /data/adb/agent2api/tmp ] || exit 27',
            'rm() { [ "$1" = -rf ] || return 31; '
            '[ "$2" = "$expected_install" ] || return 32; '
            '[ "$2" != "$TMPD" ] || return 33; printf cleanup-install-only; }',
            cleanup_lines[-1] + ' || exit 28',
        ])
        assert run(script, customize_assignments + '\n') == 'cleanup-install-only'

    check('fallback same-shell customize variable mutation cleans installer only (mock rm)', fallback_lifecycle)

    def negative_controls():
        # Demonstrate that the test can detect both old behaviors without touching files.
        old_layout = re.sub(r'  # Never inherit.*?  export TMPDIR\n', '', layout, flags=re.S)
        script = assignments + '\n' + old_layout + '\n' + '\n'.join([
            'chmod() { :; }; live_link_refresh() { :; }',
            'TMPDIR=/old/cache; export TMPDIR; ensure_layout',
            '[ "$TMPDIR" = /old/cache ] || exit 34',
        ])
        run(script)
        old_fallback = '\n'.join([
            'TMPD=/data/local/tmp/agent2api_install.$$; original=$TMPD',
            '. ' + quote(shell_path(assignment_file)),
            '[ "$TMPD" != "$original" ] && [ "$TMPD" = /data/adb/agent2api/tmp ] || exit 35',
        ])
        run(old_fallback, customize_assignments + '\n')

    check('negative controls expose old inherited-TMPDIR and fallback TMPD collision', negative_controls)
    report = {
        'module': str(module), 'shell': args.sh,
        'source_sha256': {str(paths[key]): hashlib.sha256(text.encode()).hexdigest()
                          for key, text in source.items()},
        'tests': outcomes,
        'passed': sum(item['status'] == 'PASS' for item in outcomes),
        'failed': sum(item['status'] == 'FAIL' for item in outcomes),
        'blocked': sum(item['status'] == 'BLOCKED' for item in outcomes),
        'coverage': 'host sh production fragments; no actual Android/mksh, no C dynamic spawn test',
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report['failed'] else (2 if report['blocked'] else 0)


if __name__ == '__main__':
    sys.exit(main())
