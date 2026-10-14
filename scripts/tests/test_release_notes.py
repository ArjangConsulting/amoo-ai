"""Release notes are grouped from commit subjects, not GitHub's pull-request-only generator."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'release_notes', pathlib.Path(__file__).resolve().parents[1] / 'ci' / 'release-notes.py')
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ClassificationTests(unittest.TestCase):
    def test_conventional_types_land_in_reader_facing_sections(self):
        self.assertEqual(notes.classify('feat(mcp): add device_hint', ''),
                         ('Added', 'mcp', 'add device_hint'))
        self.assertEqual(notes.classify('fix(android): stop the companion', ''),
                         ('Fixed', 'android', 'stop the companion'))
        self.assertEqual(notes.classify('perf(core): cache element lookups', ''),
                         ('Performance', 'core', 'cache element lookups'))
        self.assertEqual(notes.classify('refactor: split the tool executor', ''),
                         ('Changed', None, 'split the tool executor'))
        self.assertEqual(notes.classify('docs: document lease ports', ''),
                         ('Documentation', None, 'document lease ports'))
        self.assertEqual(notes.classify('ci(release): install protoc', ''),
                         ('Maintenance', 'release', 'install protoc'))

    def test_direct_commits_are_kept_instead_of_being_dropped(self):
        # Trunk-based history has plenty of these; GitHub's generator shows none of them.
        subject = 'Fix Android E2E fixtures and enforce platform test coverage'
        self.assertEqual(notes.classify(subject, ''), ('Other', None, subject))

    def test_bang_marker_promotes_a_commit_out_of_its_type_section(self):
        self.assertEqual(notes.classify('feat(api)!: drop the v1 tool', ''),
                         ('Breaking Changes', 'feat(api)', 'drop the v1 tool'))

    def test_breaking_change_footer_promotes_a_commit(self):
        body = 'Rework the transport.\n\nBREAKING CHANGE: tool X is gone'
        self.assertEqual(notes.classify('fix(mcp): rework the transport', body),
                         ('Breaking Changes', 'fix(mcp)', 'rework the transport'))

    def test_breaking_change_mentioned_mid_line_is_not_a_footer(self):
        body = 'Docs mention BREAKING CHANGE: elsewhere in prose'
        self.assertEqual(notes.classify('fix(mcp): rework the transport', body),
                         ('Fixed', 'mcp', 'rework the transport'))


class PreviousTagTests(unittest.TestCase):
    def test_picks_the_greatest_semver_below_the_release(self):
        tags = ['0.1.0', '0.2.0', '0.2.1', 'local-pre-rewrite-0.1.0']
        self.assertEqual(notes.previous_tag('0.3.0', tags), '0.2.1')
        self.assertEqual(notes.previous_tag('0.2.1', tags), '0.2.0')
        self.assertIsNone(notes.previous_tag('0.1.0', tags))

    def test_orders_components_numerically_not_lexically(self):
        self.assertEqual(notes.previous_tag('0.11.0', ['0.9.0', '0.10.0']), '0.10.0')


class RenderTests(unittest.TestCase):
    def render(self, entries, previous=None):
        return notes.render('0.3.0', previous, iter(entries), 'owner/name')

    def test_groups_sections_in_scan_order_and_links_commits(self):
        body = self.render([
            ('a' * 40, 'ci: bump the cache key', ''),
            ('b' * 40, 'feat(studio): execute plans', ''),
            ('c' * 40, 'fix: guard the port probe', ''),
        ], previous='0.2.1')

        self.assertLess(body.index('### Added'), body.index('### Fixed'))
        self.assertLess(body.index('### Fixed'), body.index('### Maintenance'))
        self.assertIn('- **studio:** execute plans ([`bbbbbbb`](https://github.com/owner/name/commit/'
                      f'{"b" * 40}))', body)
        self.assertIn('- guard the port probe', body)
        self.assertIn('**Full Changelog**: https://github.com/owner/name/compare/0.2.1...0.3.0', body)

    def test_first_release_links_the_commit_list_instead_of_a_compare(self):
        body = self.render([('a' * 40, 'feat: first cut', '')])
        self.assertIn('https://github.com/owner/name/commits/0.3.0', body)
        self.assertNotIn('/compare/', body)

    def test_breaking_changes_render_first_and_only_once(self):
        body = self.render([
            ('a' * 40, 'feat(api)!: drop the v1 tool', ''),
            ('b' * 40, 'fix: guard the port probe', ''),
        ])
        self.assertLess(body.index('### Breaking Changes'), body.index('### Fixed'))
        self.assertEqual(body.count('drop the v1 tool'), 1)
        self.assertIn('- **feat(api):** drop the v1 tool', body)


class HighlightsTests(unittest.TestCase):
    def test_summary_is_bounded_and_prioritizes_features(self):
        entries = [('a' * 40, f'ci: maintenance {i}', '') for i in range(8)]
        entries.append(('b' * 40, 'feat: device recording', ''))
        body = notes.render_highlights('0.3.0', '0.2.0', entries, 'owner/name')
        self.assertEqual(sum(line.startswith('- ') for line in body.splitlines()), 5)
        self.assertIn('- device recording', body)
        self.assertIn('/compare/0.2.0...0.3.0', body)

    def test_editorial_highlights_replace_automatic_summary(self):
        body = notes.render_highlights('0.3.0', None,
                                       [('a' * 40, 'ci: internal work', '')],
                                       'owner/name', '\n- Faster recording\n')
        self.assertIn('- Faster recording', body)
        self.assertNotIn('internal work', body)


class HistoryTests(unittest.TestCase):
    def test_reads_commits_and_tags_from_a_real_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                subprocess.run(('git', *args), cwd=directory, check=True, capture_output=True)

            git('init', '-q')
            git('config', 'user.email', 'release@example.com')
            git('config', 'user.name', 'Release Test')
            tracked = pathlib.Path(directory) / 'tracked.txt'
            tracked.write_text('1')
            git('add', 'tracked.txt')
            git('commit', '-q', '-m', 'feat: first cut')
            git('tag', '0.1.0')
            tracked.write_text('2')
            git('commit', '-q', '-am', 'fix: guard the port probe\n\nA multi-line body\nstill parses.')

            self.assertEqual(notes.all_tags(cwd=directory), ['0.1.0'])
            self.assertTrue(notes.tag_exists('0.1.0', cwd=directory))
            self.assertFalse(notes.tag_exists('0.3.0', cwd=directory))

            sha, subject, body = next(notes.commits('0.1.0..HEAD', cwd=directory))
            self.assertEqual(len(sha), 40)
            self.assertEqual(len(list(notes.commits('HEAD', cwd=directory))), 2)
            self.assertTrue(all(len(entry[0]) == 40
                                for entry in notes.commits('HEAD', cwd=directory)))
            self.assertEqual(subject, 'fix: guard the port probe')
            self.assertEqual(body.strip().splitlines(), ['A multi-line body', 'still parses.'])


if __name__ == '__main__':
    unittest.main()
