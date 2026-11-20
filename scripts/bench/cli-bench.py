#!/usr/bin/env python3
"""Measure how efficiently amoo's CLI runs checked-in device flows.

Runs each scenario's flow several times on one device, with telemetry and sessions isolated per
scenario, then reports pass rate, wall time, bytes the caller has to read, tool calls, failed calls
and response size. Use it to prove the CLI is cheap and reliable before wrapping it in a subagent
or MCP, and with --baseline to see whether an amoo change made a scenario better or worse.

  cli-bench.py run --manifest bench.json [--runs 3] [--out result.json] [--baseline prev.json]
  cli-bench.py env --dir <dir>          print exports that isolate a manual or agent session
  cli-bench.py report --dir <dir>       summarise such a session from its telemetry

The manifest (paths relative to it):
  {"platform": "ios", "app_id": "com.example.app", "build_path": "App.app", "device": "<udid>",
   "scenarios": [{"name": "login", "flow": "flows/login.amoo.json", "vars": {"user": "demo"}}]}
`device` and `build_path` expand $VARS, so a committed manifest needs no machine-specific paths.
A var value of `@date`, `@date-1` or `@date+2` becomes that local day as Y-M-D, for date-keyed IDs.
"""

import argparse
import json
import os
import pathlib
import re
import statistics
import subprocess
import sys
import tempfile
import time

DEFAULT_AMOO = 'amoo'
STEP_LINE = re.compile(
    r'^(?P<mark>[✓✗–])\s+(?P<index>\d+)\.\s+(?P<name>[^:]+?)(?P<optional>\s+\(optional\))?(?::\s*(?P<detail>.*))?$'
)


def parse_flow_output(text):
    """Returns one {index, name, passed, detail} per step line that `amoo flow` printed."""
    steps = []
    for line in text.splitlines():
        match = STEP_LINE.match(line.strip())
        if match:
            steps.append({
                'index': int(match['index']),
                'name': match['name'].strip(),
                'passed': match['mark'] == '✓',
                'optional': match['mark'] == '–' or bool(match['optional']),
                'detail': (match['detail'] or '').strip(),
            })
    return steps


def flow_outcome(completed, attempt):
    steps = parse_flow_output(completed.stdout + '\n' + completed.stderr)
    failed = next((step for step in steps if not step['passed']), None)
    if failed:
        failure = f"run {attempt} step {failed['index']} {failed['name']}: {failed['detail'][:160]}"
    elif completed.returncode:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        failure = f'run {attempt}: amoo exited {completed.returncode}'
        if detail:
            failure += f': {detail[-1][:160]}'
    elif not steps:
        failure = f'run {attempt}: amoo reported no flow steps'
    else:
        failure = None
    return steps, failure


def summarize_usage(report):
    """Totals across tools from `amoo usage report --json`, split by surface."""
    tools = report.get('tools', [])
    surfaces = {}
    for tool in tools:
        for surface, count in (tool.get('surfaces') or {}).items():
            surfaces[surface] = surfaces.get(surface, 0) + count
    return {
        'calls': sum(t.get('calls', 0) for t in tools),
        'failures': sum(t.get('failures', 0) for t in tools),
        'response_bytes': sum(t.get('responseBytes', 0) for t in tools),
        'inline_image_bytes': sum(t.get('inlineImageBytes', 0) for t in tools),
        'saved_images': sum(t.get('savedImages', 0) for t in tools),
        'surfaces': surfaces,
        'failed_tools': {t['tool']: t['failures'] for t in tools if t.get('failures')},
        'recommendations': report.get('recommendations', []),
    }


def flaky_steps(runs):
    """Step names that passed in some runs and failed in others."""
    outcomes = {}
    for run in runs:
        for step in run['steps']:
            outcomes.setdefault(step['name'], set()).add(step['passed'])
    return sorted(name for name, seen in outcomes.items() if seen == {True, False})


def summarize_scenario(name, runs, usage):
    contended = [run for run in runs if run.get('contended')]
    runs = [run for run in runs if not run.get('contended')]
    walls = [run['wall_s'] for run in runs]
    stdout_bytes = [run['stdout_bytes'] for run in runs]
    count = max(len(runs), 1)
    return {
        'scenario': name,
        'runs': len(runs),
        'contended_runs': len(contended),
        'load1_p50': statistics.median([run['load1'] for run in runs if 'load1' in run]) if any('load1' in run for run in runs) else None,
        'passed': sum(1 for run in runs if run['passed']),
        'wall_p50_s': round(statistics.median(walls), 1) if walls else None,
        'wall_max_s': round(max(walls), 1) if walls else None,
        'stdout_bytes_p50': int(statistics.median(stdout_bytes)) if stdout_bytes else None,
        'calls_per_run': round(usage['calls'] / count, 1),
        'failed_calls_per_run': round(usage['failures'] / count, 1),
        'response_kb_per_run': round(usage['response_bytes'] / 1024 / count, 1),
        'inline_image_bytes': usage['inline_image_bytes'],
        'surfaces': usage['surfaces'],
        'failed_tools': usage['failed_tools'],
        'flaky_steps': flaky_steps(runs),
        'first_failures': [run['first_failure'] for run in runs if run['first_failure']],
        'optional_failures': sorted({name for run in runs for name in run.get('optional_failures', [])}),
        'amoo_exit_nonzero': sum(1 for run in runs if run.get('amoo_exit', 0) != 0),
        'recommendations': usage['recommendations'],
    }


COMPARED = [
    ('pass', lambda s: s['passed'] / s['runs'] if s['runs'] else 0, True),
    ('wall_p50_s', lambda s: s['wall_p50_s'], False),
    ('calls_per_run', lambda s: s['calls_per_run'], False),
    ('failed_calls_per_run', lambda s: s['failed_calls_per_run'], False),
    ('response_kb_per_run', lambda s: s['response_kb_per_run'], False),
]


def compare(current, baseline):
    """Per-scenario changes against a baseline result; `better` is None when unchanged."""
    previous = {s['scenario']: s for s in baseline.get('scenarios', [])}
    changes = []
    for scenario in current['scenarios']:
        before = previous.get(scenario['scenario'])
        if not before:
            continue
        for metric, value, higher_is_better in COMPARED:
            old, new = value(before), value(scenario)
            if old is None or new is None or old == new:
                continue
            changes.append({
                'scenario': scenario['scenario'], 'metric': metric, 'before': old, 'after': new,
                'better': (new > old) == higher_is_better,
            })
    return changes


def format_table(result):
    header = ['scenario', 'pass', 'wall p50', 'wall max', 'stdout B', 'calls/run', 'failed/run',
              'resp KB/run', 'host load', 'flaky steps']
    rows = [header]
    for s in result['scenarios']:
        rows.append([
            s['scenario'], f"{s['passed']}/{s['runs']}", f"{s['wall_p50_s']}s", f"{s['wall_max_s']}s",
            str(s['stdout_bytes_p50']), str(s['calls_per_run']), str(s['failed_calls_per_run']),
            str(s['response_kb_per_run']), str(s.get('load1_p50', '-')), ', '.join(s['flaky_steps']) or '-',
        ])
    widths = [max(len(row[i]) for row in rows) for i in range(len(header))]
    lines = ['  '.join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip() for row in rows]
    for s in result['scenarios']:
        for failure in s['first_failures']:
            lines.append(f"  {s['scenario']}: first failure: {failure}")
        if s.get('contended_runs'):
            lines.append(f"  {s['scenario']}: {s['contended_runs']} run(s) excluded because another test used the device")
        if s.get('optional_failures'):
            lines.append(f"  {s['scenario']}: optional steps failed (counted as failures): "
                         f"{', '.join(s['optional_failures'])}")
        if s.get('amoo_exit_nonzero'):
            lines.append(f"  {s['scenario']}: amoo exited nonzero in {s['amoo_exit_nonzero']}/{s['runs']} runs")
        if s['inline_image_bytes']:
            lines.append(f"  {s['scenario']}: {s['inline_image_bytes']} inline image bytes")
        for note in s['recommendations']:
            lines.append(f"  {s['scenario']}: {note}")
    return '\n'.join(lines)


def format_changes(changes):
    if not changes:
        return 'No changes against the baseline.'
    return '\n'.join(
        f"  {'better' if c['better'] else 'WORSE '}  {c['scenario']}  {c['metric']}: {c['before']} -> {c['after']}"
        for c in changes
    )


def isolated_env(directory):
    directory = pathlib.Path(directory)
    return {
        'AMOO_TELEMETRY_DIR': str(directory / 'telemetry'),
        'AMOO_SESSIONS_DIR': str(directory / 'sessions'),
    }


def usage_report(amoo, directory):
    env = isolated_env(directory)
    completed = subprocess.run(
        [amoo, 'usage', 'report', '--telemetry-dir', env['AMOO_TELEMETRY_DIR'],
         '--sessions-dir', env['AMOO_SESSIONS_DIR'], '--transcripts', 'none', '--json'],
        capture_output=True, text=True, check=False,
    )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {'tools': [], 'recommendations': [f'usage report unreadable: {completed.stderr.strip()[:200]}']}


def device_conflicts(amoo, device, own_runtime=None):
    """Reasons the device is not free: another amoo runtime holds it, or someone's xcodebuild test targets it.

    The benchmark's own runtime and its companion (an `xcodebuild -xctestrun` of the amoo companion) are ignored.
    """
    reasons = []
    listing = subprocess.run([amoo, 'env', 'list', '--json'], capture_output=True, text=True, check=False)
    try:
        for runtime in json.loads(listing.stdout).get('runtimes', []):
            if (runtime.get('device') == device and runtime.get('state') == 'running'
                    and runtime.get('runtime_id') != own_runtime):
                reasons.append(f"amoo runtime {runtime.get('runtime_id')} owned by {runtime.get('owner')}")
    except json.JSONDecodeError:
        pass
    pids = subprocess.run(['pgrep', '-x', 'xcodebuild'], capture_output=True, text=True, check=False).stdout.split()
    for pid in pids:
        line = subprocess.run(['ps', '-o', 'args=', '-p', pid], capture_output=True, text=True,
                              check=False).stdout.strip()
        if ' test' not in line or 'AmooCompanion' in line:
            continue
        targets_other_device = 'id=' in line and device not in line
        if not targets_other_device:
            reasons.append(f'xcodebuild test (pid {pid}) may target this device')
    return reasons


def run_scenario(amoo, manifest, scenario, runs, work_dir):
    directory = pathlib.Path(work_dir) / scenario['name']
    directory.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, **isolated_env(directory)}
    up_args = [amoo, 'env', 'up', '--platform', manifest['platform'], '--device', manifest['device'],
               '--app-id', manifest['app_id'], '--owner', 'cli-bench', '--json']
    if manifest.get('build_path'):
        up_args += ['--app', manifest['build_path']]
    up = subprocess.run(up_args, capture_output=True, text=True, env=env, check=False)
    try:
        runtime = json.loads(up.stdout)
    except json.JSONDecodeError:
        runtime = {}
    if not runtime.get('ok'):
        raise RuntimeError(f"env up failed for {scenario['name']}: {(up.stdout or up.stderr).strip()[:300]}")
    results = []
    try:
        for attempt in range(1, runs + 1):
            args = [amoo, 'flow', scenario['flow'], '--device', manifest['device'], '--port', str(runtime['port']),
                    '--runtime-id', runtime['runtime_id'], '--output-dir', str(directory / f'run{attempt}')]
            for key, value in (scenario.get('vars') or {}).items():
                args += ['--var', f'{key}={resolve_var(value)}']
            contention = device_conflicts(amoo, manifest['device'], runtime['runtime_id'])
            started = time.monotonic()
            completed = subprocess.run(args, capture_output=True, text=True, env=env, check=False)
            wall = time.monotonic() - started
            contention += device_conflicts(amoo, manifest['device'], runtime['runtime_id'])
            steps, failure = flow_outcome(completed, attempt)
            results.append({
                'attempt': attempt,
                'load1': round(os.getloadavg()[0], 1),
                'contended': sorted(set(contention)),
                'passed': failure is None,
                'amoo_exit': completed.returncode,
                'optional_failures': [s['name'] for s in steps if not s['passed'] and s['optional']],
                'wall_s': wall,
                'stdout_bytes': len(completed.stdout.encode()),
                'steps': steps,
                'first_failure': failure,
            })
            note = ' (contended: another test used the device)' if contention else ''
            print(f"  {scenario['name']} run {attempt}: {'pass' if results[-1]['passed'] else 'FAIL'}{note} "
                  f'in {wall:.1f}s', file=sys.stderr)
    finally:
        subprocess.run([amoo, 'env', 'down', '--runtime-id', runtime['runtime_id'], '--json'],
                       capture_output=True, text=True, env=env, check=False)
    return summarize_scenario(scenario['name'], results, summarize_usage(usage_report(amoo, directory)))


DATE_VAR = re.compile(r'^@date(?P<offset>[+-]\d+)?$')


def resolve_var(value, today=None):
    """`@date`, `@date-1`, `@date+2`: that local day as Y-M-D without zero padding; other values as given."""
    match = DATE_VAR.match(str(value))
    if not match:
        return value
    import datetime
    day = (today or datetime.date.today()) + datetime.timedelta(days=int(match['offset'] or 0))
    return f'{day.year}-{day.month}-{day.day}'


def load_manifest(path):
    path = pathlib.Path(path).resolve()
    manifest = json.loads(path.read_text())
    base = path.parent
    for key in ('device', 'build_path'):
        if manifest.get(key):
            manifest[key] = os.path.expandvars(os.path.expanduser(manifest[key]))
            if '$' in manifest[key]:
                raise SystemExit(f'{key} still has an unset variable: {manifest[key]}')
    if manifest.get('build_path'):
        manifest['build_path'] = str((base / manifest['build_path']).resolve())
    for scenario in manifest['scenarios']:
        scenario['flow'] = str((base / scenario['flow']).resolve())
    return manifest


def command_run(args):
    manifest = load_manifest(args.manifest)
    selected = [s for s in manifest['scenarios'] if not args.scenario or s['name'] in args.scenario]
    if args.runs < 1 or not selected:
        print('A benchmark needs a positive --runs count and at least one selected scenario.', file=sys.stderr)
        return 2
    conflicts = device_conflicts(args.amoo, manifest['device'])
    if conflicts and not args.ignore_conflicts:
        print('Device is not free; results would measure contention, not amoo:', file=sys.stderr)
        for reason in conflicts:
            print(f'  {reason}', file=sys.stderr)
        print('Pick another device in the manifest or pass --ignore-conflicts.', file=sys.stderr)
        return 2
    work_dir = args.work_dir or tempfile.mkdtemp(prefix='amoo-cli-bench-')
    result = {
        'schema': 1,
        'amoo': subprocess.run([args.amoo, 'version'], capture_output=True, text=True, check=False).stdout.strip(),
        'device': manifest['device'],
        'runs': args.runs,
        'work_dir': work_dir,
        'scenarios': [run_scenario(args.amoo, manifest, s, args.runs, work_dir) for s in selected],
    }
    print(format_table(result))
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(result, indent=2) + '\n')
    if args.baseline:
        print('\nAgainst baseline:')
        print(format_changes(compare(result, json.loads(pathlib.Path(args.baseline).read_text()))))
    return 0 if all(s['runs'] > 0 and s['passed'] == s['runs'] for s in result['scenarios']) else 1


def command_env(args):
    for key, value in isolated_env(args.dir).items():
        print(f'export {key}={value}')
    return 0


def command_report(args):
    usage = summarize_usage(usage_report(args.amoo, args.dir))
    print(json.dumps(usage, indent=2))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--amoo', default=os.environ.get('AMOO', DEFAULT_AMOO), help='amoo executable')
    commands = parser.add_subparsers(dest='command', required=True)
    run = commands.add_parser('run', help='run every scenario in a manifest')
    run.add_argument('--manifest', required=True)
    run.add_argument('--runs', type=int, default=3)
    run.add_argument('--scenario', action='append', help='only this scenario (repeatable)')
    run.add_argument('--out', help='write the JSON result here (use it as a later --baseline)')
    run.add_argument('--baseline', help='an earlier --out result to compare against')
    run.add_argument('--work-dir', help='keep run output and telemetry here (default: a temp directory)')
    run.add_argument('--ignore-conflicts', action='store_true', help='run even if the device looks busy')
    run.set_defaults(handler=command_run)
    env = commands.add_parser('env', help='print exports that isolate a manual or agent session')
    env.add_argument('--dir', required=True)
    env.set_defaults(handler=command_env)
    report = commands.add_parser('report', help='summarise an isolated session directory')
    report.add_argument('--dir', required=True)
    report.set_defaults(handler=command_report)
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == '__main__':
    sys.exit(main())
