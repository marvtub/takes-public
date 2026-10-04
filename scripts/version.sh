#!/bin/bash
# Prints "VERSION BUILD" for this checkout, so nobody bumps a version by hand (2026-10-04).
# VERSION is the date of the newest commit (2026.10.4): it tells at a glance how old a build is.
# BUILD is the number of commits on main up to HEAD: it only grows, as macOS and iOS expect.
# Outside a git checkout (the phone's refresh mirror) it prints nothing, and the defaults stay.
cd "$(dirname "$0")/.." || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
echo "$(TZ=America/Los_Angeles git log -1 --date=format-local:'%Y.%-m.%-d' --format=%cd) $(git rev-list --count HEAD)"
