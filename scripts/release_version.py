#!/usr/bin/env python3
"""Resolve release versions without modifying the working tree or creating tags."""

import argparse
import re
import subprocess
from pathlib import Path


STABLE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def parse_stable(version):
    if not STABLE.fullmatch(version):
        raise ValueError(f"Expected a stable major.minor.patch version: {version!r}")
    return tuple(map(int, version.split(".")))


def stable_tags(tags):
    return [parse_stable(tag[1:]) for tag in tags
            if tag.startswith("v") and STABLE.fullmatch(tag[1:])]


def automatic_version(minimum, tags, head_tags):
    floor = parse_stable(minimum)
    # A rerun of an already tagged commit must not create another release.
    existing = stable_tags(head_tags)
    if existing:
        selected = max(existing)
    else:
        latest = max(stable_tags(tags), default=(0, 0, 0))
        selected = max(floor, (latest[0], latest[1], latest[2] + 1))
    return ".".join(map(str, selected))


def explicit_version(raw):
    version = raw.removeprefix("v")
    # Keep manual prereleases available; reject shell/path/control characters.
    base, separator, suffix = version.partition("-")
    parse_stable(base)
    if separator and not re.fullmatch(r"[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*", suffix):
        raise ValueError(f"Invalid prerelease suffix: {suffix!r}")
    return version


def git_tags(*args):
    return subprocess.check_output(["git", "tag", *args], text=True).splitlines()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Explicit manual version or pushed tag")
    args = parser.parse_args()
    if args.version is not None:
        version = explicit_version(args.version)
    else:
        minimum = (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip()
        version = automatic_version(minimum, git_tags(), git_tags("--points-at", "HEAD"))
    print(f"tag=v{version}")
    print(f"version={version}")


if __name__ == "__main__":
    main()
