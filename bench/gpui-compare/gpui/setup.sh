#!/bin/sh
# Fetches zed at the pinned commit into ./zed (gpui's source; ignored by git).
set -eu
ZED_COMMIT=26363aabdb31a0c016728634202e1ad5067033aa
cd "$(dirname "$0")"
mkdir -p zed
cd zed
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/zed-industries/zed
git fetch -q --depth 1 origin "$ZED_COMMIT"
git checkout -q FETCH_HEAD
