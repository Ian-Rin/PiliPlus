#!/usr/bin/env bash
# The "Sync upstream" step of fork-ios.yml: merges upstream PiliPlus's new
# commits into the checkout before the build. The merge reaches main only
# once the build has succeeded (the fork-build-ios action's push-merge).
#
# Nothing new upstream: the build goes on as it is. A merge that conflicts,
# or breaks thread-ripper's tests, is left out (the build goes on without it;
# the run's summary says why), as is one that changes upstream's workflow
# files, which GITHUB_TOKEN may not push: the daily sync
# (fork-sync-upstream.yml) reports those.
#
# Sets the step output merged=true when it merged. Needs dart (Flutter).
set -eo pipefail

summary() { cat >> "$GITHUB_STEP_SUMMARY"; }

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# The fork keeps its own README (.gitattributes: merge=ours).
git config merge.ours.driver true
git remote add upstream https://github.com/bggRGjQaUbCoE/PiliPlus.git 2>/dev/null || true
git fetch -q upstream main

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "上游没有新提交，直接编译。" | tee /dev/stderr | summary
  exit 0
fi

commits="$(git log --oneline HEAD..upstream/main)"
echo "上游的新提交："
echo "$commits"

workflows="$(git diff --name-only HEAD...upstream/main -- .github/workflows)"
if [ -n "$workflows" ]; then
  {
    echo "上游有新提交，但改了工作流文件，编译用的令牌推不上去，这次不合并（交给每天的同步流程）："
    echo '```'
    echo "$workflows"
    echo '```'
  } | tee /dev/stderr | summary
  exit 0
fi

before="$(git rev-parse HEAD)"
if ! git merge -q --no-edit upstream/main; then
  {
    echo "**上游合并有冲突，这次不合并，只编译本仓库的代码。**冲突的文件："
    echo '```'
    git diff --name-only --diff-filter=U
    echo '```'
  } | tee /dev/stderr | summary
  git merge --abort
  exit 0
fi

if ! (cd packages/thread_ripper && dart pub get && dart test); then
  echo "**合并上游后线程撕裂者的测试失败，这次不合并，只编译本仓库的代码。**" | tee /dev/stderr | summary
  git reset -q --hard "$before"
  exit 0
fi

{
  echo "已合并上游的新提交（编译成功后推送到 main）："
  echo '```'
  echo "$commits"
  echo '```'
} | summary
echo "merged=true" >> "$GITHUB_OUTPUT"
