#!/usr/bin/env bash
# The "Check" job of fork-ios.yml: whether this build would make an app other
# than the last release's. Not when the app's code (all but .github, docs,
# tool and Markdown) is the same as the release's and upstream has nothing
# new: a change to the build itself, say, makes the same app again.
# FORCE=true (a run started by hand with "force") builds regardless.
#
# Sets the step output build=true or build=false. Needs GH_TOKEN.
set -eo pipefail

summary() { tee -a "$GITHUB_STEP_SUMMARY"; }
decide() { echo "build=$1" >> "$GITHUB_OUTPUT"; }

if [ "$FORCE" = "true" ]; then
  echo "手动要求编译。" | summary
  decide true
  exit 0
fi

last="$(gh release view -R "$GITHUB_REPOSITORY" --json tagName -q .tagName 2>/dev/null || true)"
git fetch -q --tags origin || true
if [ -z "$last" ] || ! git rev-parse -q --verify "refs/tags/$last^{commit}" >/dev/null; then
  echo "找不到上一个 Release，编译。" | summary
  decide true
  exit 0
fi

git fetch -q https://github.com/bggRGjQaUbCoE/PiliPlus.git main
if ! git merge-base --is-ancestor FETCH_HEAD HEAD; then
  echo "上游有新提交，编译（先合并上游）。" | summary
  decide true
  exit 0
fi

app=(. ':(exclude).github' ':(exclude)docs' ':(exclude)tool' ':(exclude)*.md')
if git diff --quiet "$last" HEAD -- "${app[@]}"; then
  echo "App 代码和上一版 $last 完全相同，上游也没有新提交：跳过编译。" | summary
  decide false
else
  {
    echo "App 代码比上一版 $last 有改动，编译："
    echo '```'
    git diff --stat=100 "$last" HEAD -- "${app[@]}" | tail -n 25
    echo '```'
  } | summary
  decide true
fi
