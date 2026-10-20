import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'build-provenance.sh'


class BuildVersionTests(unittest.TestCase):
    def test_versions_follow_tags_and_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            repo = root / 'repo'
            repo.mkdir()
            output = root / 'output'

            def git(*arguments):
                return subprocess.check_output(['git', '-C', str(repo), *arguments], text=True).strip()

            def version():
                subprocess.run(['sh', str(SCRIPT), str(repo), str(output)], check=True)
                return (output / 'CompiledBuildProvenance.swift').read_text().splitlines()[2].strip()

            self.assertEqual(version(), 'static let version: String? = nil')
            git('init', '-q')
            git('config', 'user.email', 'test@example.com')
            git('config', 'user.name', 'Test')
            (repo / 'Sources').mkdir()
            source = repo / 'Sources' / 'example.swift'
            source.write_text('initial')
            git('add', '.')
            git('commit', '-qm', 'Initial')
            self.assertEqual(version(), 'static let version: String? = nil')
            git('tag', '1.2.3')
            self.assertEqual(version(), 'static let version: String? = "1.2.3"')
            source.write_text('changed')
            self.assertEqual(version(), 'static let version: String? = "1.2.3+dirty"')
            git('commit', '-qam', 'Change')
            revision = git('rev-parse', '--short=12', 'HEAD')
            expected = f'1.2.3+1.g{revision}'
            self.assertEqual(version(), f'static let version: String? = "{expected}"')
            source.write_text('changed again')
            self.assertEqual(version(), f'static let version: String? = "{expected}.dirty"')
