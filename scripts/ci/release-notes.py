#!/usr/bin/env python3
"""Render GitHub release notes from the commits since the previous release tag.

GitHub's built-in `generate_release_notes` only lists merged pull requests, and this repository is
trunk-based — releases are cut from commits pushed straight to `main`, so those notes come out as an
empty "Full Changelog" line. The commits themselves are conventional and descriptive, so group them
by type instead.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess

SEMVER = re.compile(r'^(\d+)\.(\d+)\.(\d+)$')
SUBJECT = re.compile(r'^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:\s*(?P<description>\S.*)$')

# Conventional-commit types mapped onto the sections readers scan for. Order here is the order the
# sections render in; every commit lands in exactly one section so nothing is silently dropped.
SECTIONS = (
    ('Added', ('feat',)),
    ('Fixed', ('fix',)),
    ('Performance', ('perf',)),
    ('Changed', ('refactor', 'revert')),
    ('Documentation', ('docs',)),
    ('Maintenance', ('build', 'ci', 'chore', 'test', 'style')),
)
BREAKING = 'Breaking Changes'
OTHER = 'Other'


def run(*command, cwd=None):
    return subprocess.run(command, cwd=cwd, check=True, capture_output=True, text=True).stdout


def version_key(tag):
    return tuple(int(part) for part in SEMVER.match(tag).groups())


def previous_tag(version, tags):
    """Greatest SemVer tag strictly below `version`, or None for a first release."""
    older = [tag for tag in tags if SEMVER.match(tag) and version_key(tag) < version_key(version)]
    return max(older, key=version_key) if older else None


def tag_exists(version, cwd=None):
    return subprocess.run(
        ('git', 'rev-parse', '--verify', '--quiet', f'refs/tags/{version}'),
        cwd=cwd, capture_output=True, text=True).returncode == 0


def all_tags(cwd=None):
    return run('git', 'tag', '--list', cwd=cwd).split()


def commits(range_spec, cwd=None):
    """(full sha, subject, body) for the non-merge commits in `range_spec`, newest first."""
    # Unit-separated fields and record-separated entries: subjects are single-line but bodies are
    # multi-line, so line-based parsing would mangle them.
    output = run('git', 'log', '--no-merges', '--pretty=format:%H%x1f%s%x1f%b%x1e', range_spec,
                 cwd=cwd)
    for record in output.split('\x1e'):
        fields = record.split('\x1f')
        if len(fields) < 2 or not fields[0]:
            continue
        yield fields[0], fields[1], fields[2] if len(fields) > 2 else ''


def classify(subject, body):
    """(section, label, description) for one commit; unparseable subjects keep their subject as text."""
    match = SUBJECT.match(subject)
    if not match:
        return OTHER, None, subject
    kind, scope, description = match.group('type'), match.group('scope'), match.group('description')
    if match.group('breaking') or re.search(r'^BREAKING[ -]CHANGE:', body, re.MULTILINE):
        # A breaking commit is listed once, under Breaking Changes, tagged with its original type.
        return BREAKING, f'{kind}({scope})' if scope else kind, description
    for title, types in SECTIONS:
        if kind in types:
            return title, scope, description
    return OTHER, scope, description


def render(version, previous, entries, repo=None):
    sections = {}
    for sha, subject, body in entries:
        section, label, description = classify(subject, body)
        sections.setdefault(section, []).append((sha, label, description))

    lines = ["## What's Changed", '']
    for title in [BREAKING] + [title for title, _ in SECTIONS] + [OTHER]:
        if not sections.get(title):
            continue
        lines.append(f'### {title}')
        for sha, label, description in sections[title]:
            prefix = f'**{label}:** ' if label else ''
            link = f' ([`{sha[:7]}`](https://github.com/{repo}/commit/{sha}))' if repo else ''
            lines.append(f'- {prefix}{description}{link}')
        lines.append('')

    if previous:
        lines.append(f'**Full Changelog**: https://github.com/{repo or ""}/compare/'
                     f'{previous}...{version}')
    else:
        lines.append(f'**Full Changelog**: https://github.com/{repo or ""}/commits/{version}')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('version', help='bare SemVer being released, e.g. 0.3.0')
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''),
                        help='owner/name used for commit and compare links')
    parser.add_argument('--output', type=Path, help='also write the notes to this path')
    args = parser.parse_args()

    tags = all_tags()
    previous = previous_tag(args.version, tags)
    # `publish` creates the tag only after the binaries pass their smoke tests, so a bootstrapping
    # release has no tag yet — the commits under test are the ones HEAD points at.
    target = args.version if tag_exists(args.version) else 'HEAD'
    range_spec = f'{previous}..{target}' if previous else target

    notes = render(args.version, previous, commits(range_spec), args.repo or None)
    if args.output:
        args.output.write_text(notes)
    print(notes, end='')


if __name__ == '__main__':
    main()
