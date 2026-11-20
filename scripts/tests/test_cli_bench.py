"""The CLI benchmark parses flow output and usage reports, and compares runs against a baseline."""
import importlib.util
import pathlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'cli_bench', pathlib.Path(__file__).resolve().parents[1] / 'bench' / 'cli-bench.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

FLOW_OUTPUT = """2026-11-17T19:03:01-0500 info Amoo.Flow: starting
✓ 1. Launch Jot from a clean store: App launched: com.example.app (verified=true)
✓ 2. Open settings: Tap dispatched to element [] Settings; target state unconfirmed.
✗ 3. Find the Health access button: scroll_to_element failed: reached both ends without finding the element.
"""


def run(passed, steps, wall=10.0, stdout=500, failure=None):
    return {'passed': passed, 'wall_s': wall, 'stdout_bytes': stdout, 'steps': steps, 'first_failure': failure}


def step(name, passed):
    return {'index': 1, 'name': name, 'passed': passed, 'detail': ''}


class FlowOutputTests(unittest.TestCase):
    def test_parses_step_lines_and_ignores_log_lines(self):
        steps = bench.parse_flow_output(FLOW_OUTPUT)
        self.assertEqual([s['index'] for s in steps], [1, 2, 3])
        self.assertEqual(steps[1]['name'], 'Open settings')
        self.assertTrue(steps[0]['passed'])
        self.assertFalse(steps[2]['passed'])
        self.assertTrue(steps[2]['detail'].startswith('scroll_to_element failed'))

    def test_optional_step_line_is_parsed_as_a_failure(self):
        step = bench.parse_flow_output('– 8. Dismiss the name keyboard (optional): no keyboard')[0]
        self.assertFalse(step['passed'])
        self.assertTrue(step['optional'])
        self.assertEqual(step['name'], 'Dismiss the name keyboard')
        self.assertEqual(step['detail'], 'no keyboard')

    def test_step_without_detail(self):
        self.assertEqual(bench.parse_flow_output('✓ 4. health-access-dark')[0]['detail'], '')

    def test_nonzero_exit_fails_even_when_every_printed_step_passed(self):
        completed = subprocess.CompletedProcess(['amoo'], 1, '✓ 1. Login: ready', 'Report write failed')
        steps, failure = bench.flow_outcome(completed, 1)
        self.assertTrue(steps[0]['passed'])
        self.assertEqual(failure, 'run 1: amoo exited 1: Report write failed')


class VarTests(unittest.TestCase):
    def test_date_tokens_resolve_relative_to_today(self):
        import datetime
        today = datetime.date(2026, 1, 1)
        self.assertEqual(bench.resolve_var('@date', today), '2026-1-1')
        self.assertEqual(bench.resolve_var('@date-1', today), '2025-12-31')
        self.assertEqual(bench.resolve_var('@date+31', today), '2026-2-1')

    def test_other_values_pass_through(self):
        self.assertEqual(bench.resolve_var('Jungle'), 'Jungle')
        self.assertEqual(bench.resolve_var('x@date-1'), 'x@date-1')


class UsageTests(unittest.TestCase):
    def test_totals_across_tools_and_surfaces(self):
        usage = bench.summarize_usage({
            'tools': [
                {'tool': 'scroll', 'calls': 10, 'failures': 0, 'responseBytes': 1000, 'surfaces': {'cli': 10}},
                {'tool': 'tap_element', 'calls': 4, 'failures': 1, 'responseBytes': 400, 'inlineImageBytes': 7,
                 'surfaces': {'cli': 3, 'mcp': 1}},
            ],
            'recommendations': ['scroll was repeated'],
        })
        self.assertEqual(usage['calls'], 14)
        self.assertEqual(usage['failures'], 1)
        self.assertEqual(usage['response_bytes'], 1400)
        self.assertEqual(usage['inline_image_bytes'], 7)
        self.assertEqual(usage['surfaces'], {'cli': 13, 'mcp': 1})
        self.assertEqual(usage['failed_tools'], {'tap_element': 1})

    def test_empty_report(self):
        self.assertEqual(bench.summarize_usage({})['calls'], 0)


class ScenarioTests(unittest.TestCase):
    def test_flaky_steps_are_those_with_mixed_outcomes(self):
        runs = [run(True, [step('a', True), step('b', True)]), run(False, [step('a', True), step('b', False)])]
        self.assertEqual(bench.flaky_steps(runs), ['b'])

    def test_summary_divides_usage_per_run(self):
        usage = bench.summarize_usage({'tools': [{'tool': 'scroll', 'calls': 30, 'failures': 3,
                                                  'responseBytes': 3072}]})
        summary = bench.summarize_scenario('s', [run(True, [], wall=4), run(True, [], wall=6),
                                                 run(False, [], wall=20, failure='run 3 step 2 x: y')], usage)
        self.assertEqual(summary['passed'], 2)
        self.assertEqual(summary['wall_p50_s'], 6)
        self.assertEqual(summary['wall_max_s'], 20)
        self.assertEqual(summary['calls_per_run'], 10)
        self.assertEqual(summary['failed_calls_per_run'], 1)
        self.assertEqual(summary['response_kb_per_run'], 1)
        self.assertEqual(summary['first_failures'], ['run 3 step 2 x: y'])


class ContentionTests(unittest.TestCase):
    def test_contended_runs_are_excluded_and_counted(self):
        usage = bench.summarize_usage({})
        contended = dict(run(False, [], failure='run 2 step 1 x: y'), contended=['xcodebuild test (pid 1)'])
        summary = bench.summarize_scenario('s', [run(True, []), contended, run(True, [])], usage)
        self.assertEqual((summary['passed'], summary['runs'], summary['contended_runs']), (2, 2, 1))
        self.assertEqual(summary['first_failures'], [])

    def test_all_contended_runs_do_not_count_as_a_passing_benchmark(self):
        manifest = {'device': 'test', 'scenarios': [{'name': 'scenario'}]}
        contended = dict(run(False, []), contended=['xcodebuild test (pid 1)'])
        summary = bench.summarize_scenario('scenario', [contended], bench.summarize_usage({}))
        with patch.object(bench, 'load_manifest', return_value=manifest), \
                patch.object(bench, 'device_conflicts', return_value=[]), \
                patch.object(bench, 'run_scenario', return_value=summary), \
                patch.object(bench.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'test')), \
                patch('builtins.print'):
            self.assertEqual(bench.main(['run', '--manifest', 'fixture', '--work-dir', '/unused']), 1)


class BaselineTests(unittest.TestCase):
    def scenario(self, passed, calls):
        return {'scenario': 's', 'runs': 3, 'passed': passed, 'wall_p50_s': 10, 'calls_per_run': calls,
                'failed_calls_per_run': 0, 'response_kb_per_run': 1}

    def test_reports_direction_of_each_changed_metric(self):
        changes = bench.compare({'scenarios': [self.scenario(3, 12)]}, {'scenarios': [self.scenario(2, 20)]})
        by_metric = {c['metric']: c for c in changes}
        self.assertTrue(by_metric['pass']['better'])
        self.assertTrue(by_metric['calls_per_run']['better'])
        self.assertNotIn('wall_p50_s', by_metric)

    def test_worse_calls_are_flagged(self):
        changes = bench.compare({'scenarios': [self.scenario(3, 30)]}, {'scenarios': [self.scenario(3, 20)]})
        self.assertEqual([(c['metric'], c['better']) for c in changes], [('calls_per_run', False)])

    def test_scenarios_missing_from_baseline_are_skipped(self):
        self.assertEqual(bench.compare({'scenarios': [self.scenario(3, 1)]}, {'scenarios': []}), [])


if __name__ == '__main__':
    unittest.main()
