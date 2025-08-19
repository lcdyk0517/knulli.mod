#!/usr/bin/env bash
# 用法：
#   sudo ./mod_knulli_from_img.sh your_image.img [-u https://example.com/mod_files.tar.gz | -f /path/to/mod_files.zip]
# 功能：
#   1) 挂载镜像第4分区、解包 boot/batocera
#   2) 下载/解压 mod_files（或使用本地包/目录）
#   3) 将 mod 应用到解包目录
#   4) 重新打包并写回镜像
#   5) 出错也能清理干净

set -euo pipefail

IMG="${1:-}"
shift || true

MOD_URL="https://github.com/lcdyk0517/rocknix.sync/releases/download/knulli.mod/mod_files.zip"
MOD_ARCHIVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url) MOD_URL="$2"; shift 2 ;;
    -f|--file) MOD_ARCHIVE="$2"; shift 2 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

if [[ -z "$IMG" ]]; then
  echo "❌ 用法: sudo $0 your_image.img [-u mod_url | -f mod_archive]"
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖：$1"; exit 1; }; }
for bin in losetup mount umount unsquashfs mksquashfs realpath; do need "$bin"; done
command -v curl >/dev/null 2>&1 || [[ -n "$MOD_ARCHIVE" ]] || echo "⚠️ 没有 curl（如用 -f 指本地包可忽略）"
command -v unzip >/dev/null 2>&1 || true
command -v tar >/dev/null 2>&1 || true

IMG_PATH="$(realpath "$IMG")"
WORKROOT="$(mktemp -d -p "$(pwd)" batowork.XXXXXX)"
WORKDIR="${WORKROOT}/batocera"
MOUNT_BASE="${IMG_PATH}.mnt"
MNT_P4="${WORKROOT}/imgp4"

mkdir -p "$WORKDIR" "$MNT_P4"

LOOPDEV=""
cleanup() {
  set +e
  [[ -n "$LOOPDEV" ]] && { mountpoint -q "$MNT_P4" && umount "$MNT_P4"; losetup -d "$LOOPDEV" 2>/dev/null || true; }
  rm -rf "$WORKROOT"
}
trap cleanup EXIT

echo "🔧 映射 loop 并挂载第4分区..."
LOOPDEV=$(losetup --show -fP "$IMG_PATH")
if [[ ! -e "${LOOPDEV}p4" ]]; then
  echo "❌ 找不到分区设备 ${LOOPDEV}p4，可能镜像结构有误"
  exit 1
fi
mount "${LOOPDEV}p4" "$MNT_P4"
echo "✅ p4 挂载到 $MNT_P4"

BATOCERA_IMG="$MNT_P4/boot/batocera"
if [[ ! -f "$BATOCERA_IMG" ]]; then
  echo "❌ 找不到 boot/batocera 文件"
  exit 1
fi

echo "📦 解包 batocera.squashfs → $WORKDIR/squashfs-root"
cp "$BATOCERA_IMG" "$WORKDIR/batocera.squashfs"
pushd "$WORKDIR" >/dev/null
unsquashfs -d squashfs-root batocera.squashfs

# -----------------------------
# 准备 mod_files 到 $WORKDIR/mod_files
# -----------------------------
MOD_DIR="$WORKDIR/mod_files"
mkdir -p "$MOD_DIR"

if [[ -n "$MOD_URL" ]]; then
  echo "⬇️ 下载 mod 包：$MOD_URL"
  curl -L --fail -o "$WORKROOT/mod_files.zip" "$MOD_URL"
  MOD_ARCHIVE="$WORKROOT/mod_files.zip"
fi

# 若脚本同目录已有 mod_files 目录，也可直接用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$MOD_ARCHIVE" && -d "$SCRIPT_DIR/mod_files" ]]; then
  echo "📁 使用脚本同目录的 mod_files/"
  cp -a "$SCRIPT_DIR/mod_files/." "$MOD_DIR/"
elif [[ -n "$MOD_ARCHIVE" ]]; then
  lower="$(echo "$MOD_ARCHIVE" | tr 'A-Z' 'a-z')"
  if [[ -f "$MOD_ARCHIVE" && "$lower" == *.zip ]]; then
    unzip -q "$MOD_ARCHIVE" -d "$MOD_DIR"
  elif [[ -f "$MOD_ARCHIVE" && ( "$lower" == *.tar.gz || "$lower" == *.tgz || "$lower" == *.tar.xz || "$lower" == *.txz || "$lower" == *.tar.bz2 || "$lower" == *.tbz2 || "$lower" == *.tar ) ]]; then
    tar -xf "$MOD_ARCHIVE" -C "$MOD_DIR"
  elif [[ -d "$MOD_ARCHIVE" ]]; then
    cp -a "$MOD_ARCHIVE/." "$MOD_DIR/"
  else
    echo "❌ 无法识别的 mod 包：$MOD_ARCHIVE"
    exit 1
  fi
fi

# 若解压后外层还有一层目录，尝试剥一层
if [[ -d "$MOD_DIR/mod_files" ]]; then
  MOD_DIR="$MOD_DIR/mod_files"
fi

# -----------------------------
# 应用修改（仅作用于解包目录，不碰宿主机）
# -----------------------------
system_root="./squashfs-root"
mod_root="$MOD_DIR"

dst() { echo "${system_root}/$1"; }
src() { echo "${mod_root}/$1"; }

echo "🛠️ 应用修改..."

# 字体/文件
install -Dm644 "$(src DejaVuSansMono.ttf)" "$(dst usr/share/fonts/dejavu/DejaVuSansMono.ttf)" 2>/dev/null || true
install -Dm644 "$(src NanumMyeongjo.ttf)"   "$(dst usr/share/fonts/truetype/nanum/NanumMyeongjo.ttf)" 2>/dev/null || true
install -Dm644 "$(src Roboto-Condensed.ttf)" "$(dst usr/share/ppsspp/PPSSPP/Roboto-Condensed.ttf)" 2>/dev/null || true
install -Dm644 "$(src hostname)"             "$(dst etc/hostname)" 2>/dev/null || true

# nds
install -Dm644 "$(src nds/usrcheat.dat)" "$(dst usr/share/advanced_drastic/usrcheat.dat)" 2>/dev/null || true
install -Dm644 "$(src nds/font.ttf)"      "$(dst usr/share/advanced_drastic/resources/font/font.ttf)" 2>/dev/null || true
install -Dm644 "$(src nds/settings.json)" "$(dst usr/share/advanced_drastic/resources/settings.json)" 2>/dev/null || true

# 时区（注意：不动宿主机）
rm -f "$(dst etc/localtime)" 2>/dev/null || true
ln -sf "/usr/share/zoneinfo/Asia/Shanghai" "$(dst etc/localtime)"
install -Dm644 "$(src timezone)"      "$(dst etc/timezone)" 2>/dev/null || true
install -Dm644 "$(src batocera.conf)" "$(dst usr/share/batocera/datainit/system/batocera.conf)" 2>/dev/null || true

# libretro 核心
mkdir -p "$(dst usr/lib/libretro)" "$(dst usr/share/libretro/info)"
cp -a "$(src cores/.)" "$(dst usr/lib/libretro/)" 2>/dev/null || true
cp -a "$(src info/.)"  "$(dst usr/share/libretro/info/)" 2>/dev/null || true
chmod 775 "$(dst usr/lib/libretro)"/* 2>/dev/null || true

# ES 配置与 rom 目录
install -Dm644 "$(src es_systems.cfg)" "$(dst usr/share/emulationstation/es_systems.cfg)" 2>/dev/null || true
mkdir -p "$(dst usr/share/batocera/datainit/roms/onscripter)"

# Java 独立模拟器
cp -a "$(src java)" "$(dst usr/share/)" 2>/dev/null || true
mkdir -p "$(dst usr/share/batocera/datainit/roms/j2me)"
mkdir -p "$(dst usr/lib/python3.12/site-packages/configgen/generators)"
cp -a "$(src generators/freej2me)" "$(dst usr/lib/python3.12/site-packages/configgen/generators/)" 2>/dev/null || true
chmod 755 "$(dst usr/lib/python3.12/site-packages/configgen/generators/freej2me)"/* 2>/dev/null || true

# yabasanshiro 独立模拟器
cp -a "$(src yabasanshiro)" "$(dst usr/bin/)" 2>/dev/null || true
cp -a "$(src generators/yabasanshiro)" "$(dst usr/lib/python3.12/site-packages/configgen/generators/)" 2>/dev/null || true
chmod 755 "$(dst usr/lib/python3.12/site-packages/configgen/generators/yabasanshiro)"/* 2>/dev/null || true
chmod 755 "$(dst usr/bin/yabasanshiro)" 2>/dev/null || true

# importer.py
cp -a "$(src generators/importer.py)" "$(dst usr/lib/python3.12/site-packages/configgen/generators/importer.py)" 2>/dev/null || true

# BIOS
cp -a "$(src bios/.)" "$(dst usr/share/batocera/datainit/bios/)" 2>/dev/null || true

# 临时修改（drastic 配置）
install -Dm644 "$(src nds/drastic.cfg)" "$(dst usr/share/drastic/config/drastic.cfg)" 2>/dev/null || true
install -Dm644 "$(src nds/drastic.cfg)" "$(dst usr/share/advanced_drastic/config/drastic.cfg)" 2>/dev/null || true

echo "📦 重新打包 batocera.new..."
rm -f batocera.new
mksquashfs squashfs-root batocera.new -comp xz -noappend

echo "📝 回写镜像并同步..."
cp -f batocera.new "$BATOCERA_IMG"
sync
popd >/dev/null

echo "🧹 卸载并释放..."
umount "$MNT_P4"
losetup -d "$LOOPDEV"
LOOPDEV=""

echo "🎉 完成：镜像已更新（$IMG_PATH）"
