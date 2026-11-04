#!/bin/bash
# 在自己的 Mac 上打出和 .github/workflows/ios.yml 一样的未签名 ipa。
#
#   bash build_ios_mac.sh [分支]        # 默认 main
#
# 下载的东西全部放在一个文件夹里（默认 ~/piliplus-build，可用环境变量
# PILI_BUILD_ROOT 改）：Flutter SDK、PowerShell、项目代码、依赖缓存、
# CocoaPods 缓存、Xcode 编译缓存。用完删掉这个文件夹就清理干净了。
# 例外：Xcode 本身（App Store）和用 Homebrew 装的 CocoaPods（缺少时才装），
# 见脚本最后打印的清理说明。
#
# 为什么要单独一个 Flutter：官方脚本 lib/scripts/patch.ps1 会对 Flutter SDK
# 执行 git reset --hard 再打补丁，还会改依赖缓存里的 material_ui 等包。
set -euo pipefail

BRANCH="${1:-main}"
REPO="https://github.com/Ian-Rin/PiliPlus.git"
ROOT="${PILI_BUILD_ROOT:-$HOME/piliplus-build}"
PWSH_VERSION="7.4.6"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- Xcode -------------------------------------------------------------------
say "检查 Xcode"
if ! xcode-select -p 2>/dev/null | grep -q "\.app/"; then
  fail "没找到 Xcode。请先从 App Store 安装 Xcode，打开一次，然后运行：
  sudo xcode-select -s /Applications/Xcode.app
  sudo xcodebuild -runFirstLaunch"
fi
xcodebuild -version
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  fail "Xcode 还没完成首次设置（许可协议和组件）。请运行：
  sudo xcodebuild -runFirstLaunch"
fi

# --- CocoaPods（Flutter 的 iOS 插件要用） -----------------------------------
say "检查 CocoaPods"
INSTALLED_PODS=0
if ! command -v pod >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || fail "没有 CocoaPods，也没有 Homebrew。
先装 Homebrew（https://brew.sh），再重新运行这个脚本；或者自己装好 CocoaPods。"
  brew install cocoapods
  INSTALLED_PODS=1
fi
pod --version

mkdir -p "$ROOT"
cd "$ROOT"

# --- PowerShell（官方构建脚本是 .ps1），只解压到这个文件夹 -------------------
if [ ! -x "$ROOT/pwsh/pwsh" ]; then
  say "下载 PowerShell $PWSH_VERSION"
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    *) arch=x64 ;;
  esac
  curl -fL --retry 3 -o pwsh.tar.gz \
    "https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/powershell-$PWSH_VERSION-osx-$arch.tar.gz"
  mkdir -p pwsh
  tar -xzf pwsh.tar.gz -C pwsh
  rm pwsh.tar.gz
  chmod +x pwsh/pwsh
fi

# --- 和 CI 隔离开的家目录：依赖缓存、CocoaPods 仓库、Flutter 设置、编译缓存 ---
export HOME="$ROOT/home"
mkdir -p "$HOME"
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# --- 项目代码：每次重新 clone（构建脚本会改仓库里的文件） ---------------------
say "获取 $BRANCH 分支"
rm -rf "$ROOT/PiliPlus"
# 版本号是提交数（git rev-list --count HEAD），所以要完整历史。
git clone -b "$BRANCH" "$REPO" "$ROOT/PiliPlus"
cd "$ROOT/PiliPlus"
git log --oneline -1

# --- Flutter：pubspec.yaml 里写的版本 ----------------------------------------
FLUTTER_VERSION="$(sed -n 's/^  flutter: *\([0-9][0-9.]*\).*/\1/p' pubspec.yaml | head -1)"
[ -n "$FLUTTER_VERSION" ] || fail "pubspec.yaml 里没找到 Flutter 版本"
export FLUTTER_ROOT="$ROOT/flutter"
if [ ! -d "$FLUTTER_ROOT/.git" ] ||
  [ "$(git -C "$FLUTTER_ROOT" describe --tags 2>/dev/null)" != "$FLUTTER_VERSION" ]; then
  say "下载 Flutter $FLUTTER_VERSION"
  rm -rf "$FLUTTER_ROOT"
  git clone --depth 1 -b "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_ROOT"
fi
export PATH="$FLUTTER_ROOT/bin:$ROOT/pwsh:$PATH"
flutter --disable-analytics >/dev/null 2>&1 || true
flutter --version

# --- 和 ios.yml 相同的步骤 ----------------------------------------------------
export GITHUB_WORKSPACE="$ROOT/PiliPlus"
export GITHUB_ENV="$ROOT/github_env"
: >"$GITHUB_ENV"

say "设置版本号（lib/scripts/build.ps1）"
pwsh lib/scripts/build.ps1

say "打补丁（lib/scripts/patch.ps1 iOS）"
pwsh lib/scripts/patch.ps1 iOS

say "编译（第一次要下载很多东西，可能要 20 分钟以上）"
VERSION="$(sed -n 's/^version=//p' "$GITHUB_ENV" | tail -1)"
flutter build ios --release --no-codesign --dart-define-from-file=pili_release.json --no-pub
ln -sf ./build/ios/iphoneos Payload
find Payload/Runner.app/Frameworks -type d -name "*.framework" \
  -exec codesign --force --sign - --preserve-metadata=identifier,entitlements {} \;
IPA="$ROOT/PiliPlus_ios_${VERSION}.ipa"
rm -f "$IPA"
zip -qr9 "$IPA" Payload/Runner.app

say "完成"
echo "ipa：$IPA"
echo "提交：$(git log --oneline -1)"
echo
echo "清理："
echo "  rm -rf \"$ROOT\"      # 这个脚本下载和生成的一切"
if [ "$INSTALLED_PODS" = 1 ]; then
  echo "  brew uninstall cocoapods      # 这次用 Homebrew 装的"
fi
echo "  Xcode 从「应用程序」里删除即可（如果是为这个项目装的）"
