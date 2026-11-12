#!/bin/sh
# Runs morph.py with numpy and OpenCV through uv, the same way Takes runs its voice cleanup: the first
# run downloads Python 3.11 and the two packages into uv's cache, later runs start at once.
#
#   sh layout-morph/morph.sh --camera ../../take-02-camera.mov --size 1920x1080 --length 39.2 --plan '[...]'
set -e
here=$(cd "$(dirname "$0")" && pwd)
uv=$(command -v uv 2>/dev/null || true)
for p in /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv"; do
  [ -n "$uv" ] && break
  [ -x "$p" ] && uv=$p
done
if [ -z "$uv" ]; then
  echo "uv is missing. Clean a take's voice once (Takes installs uv then), or get it from https://docs.astral.sh/uv" >&2
  exit 2
fi
exec "$uv" run -q --python 3.11 --with numpy --with opencv-python-headless "$here/morph.py" "$@"
