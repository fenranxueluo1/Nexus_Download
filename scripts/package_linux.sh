#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINE="$(uname -m)"
case "$MACHINE" in
  x86_64) FLUTTER_ARCH="x64"; DENO_ASSET="deno-x86_64-unknown-linux-gnu.zip"; YTDLP_ASSET="yt-dlp_linux"; FFMPEG_ASSET="ffmpeg-release-amd64-static.tar.xz" ;;
  aarch64|arm64) FLUTTER_ARCH="arm64"; DENO_ASSET="deno-aarch64-unknown-linux-gnu.zip"; YTDLP_ASSET="yt-dlp_linux_aarch64"; FFMPEG_ASSET="ffmpeg-release-arm64-static.tar.xz" ;;
  *) echo "不支持的 Linux 架构：$MACHINE" >&2; exit 1 ;;
esac

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
CACHE="$OUTPUT_DIR/_cache"
STAGE="$OUTPUT_DIR/Nexus-Linux-$MACHINE"
TARBALL="$OUTPUT_DIR/NexusDownload-Linux-$MACHINE.tar.gz"
BUNDLE="$ROOT/build/linux/$FLUTTER_ARCH/release/bundle"

mkdir -p "$CACHE" "$OUTPUT_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "构建 Linux Release..."
  (cd "$ROOT" && flutter build linux --release)
fi

if [[ ! -d "$BUNDLE" ]]; then
  echo "找不到 Linux Bundle：$BUNDLE" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BUNDLE"/. "$STAGE"/
mkdir -p "$STAGE/tools" "$STAGE/ffmpeg"

# yt-dlp
if [[ -n "${YTDLP_PATH:-}" ]]; then
  cp "$YTDLP_PATH" "$STAGE/tools/yt-dlp"
else
  YTDLP_CACHE="$CACHE/$YTDLP_ASSET"
  if [[ ! -f "$YTDLP_CACHE" ]]; then
    echo "下载 yt-dlp Linux..."
    curl -fL --retry 3 \
      "https://github.com/yt-dlp/yt-dlp/releases/latest/download/$YTDLP_ASSET" \
      -o "$YTDLP_CACHE"
  fi
  cp "$YTDLP_CACHE" "$STAGE/tools/yt-dlp"
fi
chmod +x "$STAGE/tools/yt-dlp"

# Deno
if [[ -n "${DENO_PATH:-}" ]]; then
  cp "$DENO_PATH" "$STAGE/tools/deno"
else
  DENO_DIR="$CACHE/deno-linux-$MACHINE"
  if [[ ! -x "$DENO_DIR/deno" ]]; then
    rm -rf "$DENO_DIR"
    mkdir -p "$DENO_DIR"
    echo "下载 Deno Linux..."
    curl -fL --retry 3 \
      "https://github.com/denoland/deno/releases/latest/download/$DENO_ASSET" \
      -o "$CACHE/deno.zip"
    unzip -q -o "$CACHE/deno.zip" -d "$DENO_DIR"
  fi
  cp "$DENO_DIR/deno" "$STAGE/tools/deno"
fi
chmod +x "$STAGE/tools/deno"

# FFmpeg
if [[ -n "${FFMPEG_PATH:-}" ]]; then
  cp "$FFMPEG_PATH" "$STAGE/ffmpeg/ffmpeg"
else
  FFMPEG_DIR="$CACHE/ffmpeg-$MACHINE"
  if [[ ! -x "$FFMPEG_DIR/ffmpeg" ]]; then
    rm -rf "$FFMPEG_DIR"
    mkdir -p "$FFMPEG_DIR"
    echo "下载静态 FFmpeg Linux..."
    curl -fL --retry 3 \
      "https://johnvansickle.com/ffmpeg/releases/$FFMPEG_ASSET" \
      -o "$CACHE/ffmpeg.tar.xz"
    tar -xJf "$CACHE/ffmpeg.tar.xz" -C "$FFMPEG_DIR" --strip-components=1
  fi
  cp "$FFMPEG_DIR/ffmpeg" "$STAGE/ffmpeg/ffmpeg"
fi
chmod +x "$STAGE/ffmpeg/ffmpeg"

cat > "$STAGE/README.txt" <<'EOF'
Nexus Download - Linux

运行方式
1. 解压整个目录。
2. 双击 nexus_download，或终端执行 ./nexus_download。

已内置
- FFmpeg：ffmpeg/ffmpeg
- yt-dlp：tools/yt-dlp
- Deno：tools/deno

系统要求
- 主流 x64 / arm64 Linux 桌面
- GTK3、GLib、libstdc++ 等 Flutter Linux 运行库。
  Ubuntu/Debian 可安装：
  sudo apt install libgtk-3-0 libblkid1 liblzma5
- 需要网络；YouTube 下载可能需要 HTTP/HTTPS 代理

功能限制
- Linux 没有内置 WebView 登录，因此 YouTube/X/抖音的应用内登录按钮不显示。
- YouTube 可在设置中手动选择 cookies.txt。
- X、抖音可使用公开内容。

第三方组件
- yt-dlp：Unlicense
- Deno：MIT
- FFmpeg：按其发行版许可证分发
- 本项目：GNU GPL v3.0，详见 LICENSE
EOF
cp "$ROOT/LICENSE" "$STAGE/LICENSE" 2>/dev/null || true

rm -f "$TARBALL"
echo "压缩 $TARBALL ..."
tar -C "$STAGE" -czf "$TARBALL" .

echo
echo "打包完成"
echo "路径：$TARBALL"
sha256sum "$TARBALL"
echo "大小：$(du -h "$TARBALL" | awk '{print $1}')"
