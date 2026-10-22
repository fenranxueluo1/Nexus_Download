#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) DENO_ASSET="deno-aarch64-apple-darwin.zip" ;;
  x86_64) DENO_ASSET="deno-x86_64-apple-darwin.zip" ;;
  *) echo "不支持的 macOS 架构：$ARCH" >&2; exit 1 ;;
esac

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
CACHE="$OUTPUT_DIR/_cache"
STAGE="$OUTPUT_DIR/Nexus-macOS-$ARCH"
ZIP="$OUTPUT_DIR/NexusDownload-macOS-$ARCH.zip"
APP="$ROOT/build/macos/Build/Products/Release/nexus_download.app"

mkdir -p "$CACHE" "$OUTPUT_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "构建 macOS Release..."
  (cd "$ROOT" && flutter build macos --release)
fi

if [[ ! -d "$APP" ]]; then
  echo "找不到 macOS App：$APP" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/nexus_download.app"
MACOS_DIR="$STAGE/nexus_download.app/Contents/MacOS"
mkdir -p "$MACOS_DIR/tools" "$MACOS_DIR/ffmpeg"

# yt-dlp
if [[ -n "${YTDLP_PATH:-}" ]]; then
  cp "$YTDLP_PATH" "$MACOS_DIR/tools/yt-dlp"
else
  YTDLP_CACHE="$CACHE/yt-dlp_macos"
  if [[ ! -f "$YTDLP_CACHE" ]]; then
    echo "下载 yt-dlp macOS..."
    curl -fL --retry 3 \
      "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" \
      -o "$YTDLP_CACHE"
  fi
  cp "$YTDLP_CACHE" "$MACOS_DIR/tools/yt-dlp"
fi
chmod +x "$MACOS_DIR/tools/yt-dlp"

# Deno
if [[ -n "${DENO_PATH:-}" ]]; then
  cp "$DENO_PATH" "$MACOS_DIR/tools/deno"
else
  DENO_DIR="$CACHE/deno-macos-$ARCH"
  if [[ ! -x "$DENO_DIR/deno" ]]; then
    rm -rf "$DENO_DIR"
    mkdir -p "$DENO_DIR"
    echo "下载 Deno macOS..."
    curl -fL --retry 3 \
      "https://github.com/denoland/deno/releases/latest/download/$DENO_ASSET" \
      -o "$CACHE/deno.zip"
    unzip -q -o "$CACHE/deno.zip" -d "$DENO_DIR"
  fi
  cp "$DENO_DIR/deno" "$MACOS_DIR/tools/deno"
fi
chmod +x "$MACOS_DIR/tools/deno"

# FFmpeg
if [[ -n "${FFMPEG_PATH:-}" ]]; then
  FFMPEG_SOURCE="$FFMPEG_PATH"
else
  FFMPEG_SOURCE="$(command -v ffmpeg || true)"
fi
if [[ -z "$FFMPEG_SOURCE" || ! -f "$FFMPEG_SOURCE" ]]; then
  echo "找不到 ffmpeg。请安装 Homebrew ffmpeg，或用 FFMPEG_PATH 指定静态 ffmpeg。" >&2
  exit 1
fi
cp "$FFMPEG_SOURCE" "$MACOS_DIR/ffmpeg/ffmpeg"
chmod +x "$MACOS_DIR/ffmpeg/ffmpeg"
if command -v otool >/dev/null 2>&1; then
  DEPENDENCIES="$(otool -L "$MACOS_DIR/ffmpeg/ffmpeg" 2>/dev/null || true)"
  if echo "$DEPENDENCIES" | grep -E '(/opt/homebrew|/usr/local)/' >/dev/null; then
    if command -v dylibbundler >/dev/null 2>&1; then
      echo "打包 FFmpeg 动态库依赖..."
      mkdir -p "$MACOS_DIR/lib"
      dylibbundler -od -b \
        -x "$MACOS_DIR/ffmpeg/ffmpeg" \
        -d "$MACOS_DIR/lib" \
        -p "@executable_path/lib"
    else
      echo "错误：ffmpeg 依赖 Homebrew 动态库，当前包不能在其他 Mac 上开箱即用。" >&2
      echo "请安装 dylibbundler（brew install dylibbundler）后重试，或用 FFMPEG_PATH 指定静态 ffmpeg。" >&2
      exit 1
    fi
  fi
fi

cat > "$STAGE/README.txt" <<'EOF'
Nexus Download - macOS

运行方式
1. 解压后双击 nexus_download.app。
2. 如果系统提示无法验证开发者，右键 App → 打开，或执行：
   xattr -dr com.apple.quarantine nexus_download.app

已内置
- FFmpeg：nexus_download.app/Contents/MacOS/ffmpeg/ffmpeg
- yt-dlp：nexus_download.app/Contents/MacOS/tools/yt-dlp
- Deno：nexus_download.app/Contents/MacOS/tools/deno

系统要求
- macOS 12+
- 需要网络；YouTube 下载可能需要 HTTP/HTTPS 代理
- 应用内登录依赖系统 WKWebView

账号
- 进入“账号”页登录 B 站、YouTube、X、抖音。
- Cookie 仅保存在本机应用数据目录。

第三方组件
- yt-dlp：Unlicense
- Deno：MIT
- FFmpeg：按其发行版许可证分发
- 本项目：GNU GPL v3.0，详见 LICENSE
EOF
cp "$ROOT/LICENSE" "$STAGE/LICENSE" 2>/dev/null || true

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  echo "签名 App（$CODESIGN_IDENTITY）..."
  codesign --force --deep --sign "$CODESIGN_IDENTITY" \
    "$STAGE/nexus_download.app"
fi

rm -f "$ZIP"
echo "压缩 $ZIP ..."
(cd "$STAGE" && ditto -c -k --sequesterRsrc . "$ZIP")

echo
echo "打包完成"
echo "路径：$ZIP"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ZIP"
fi
echo "大小：$(du -h "$ZIP" | awk '{print $1}')"
