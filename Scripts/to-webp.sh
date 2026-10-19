#!/bin/bash
# スクリーンショット（PNG など）を、サイトや README 用の WebP に書き出す。
# macOS の sips は WebP を書き出せないので cwebp（Homebrew の webp）を使う。窓の影の透明はそのまま残し、メタデータは落とす。
#
# 使い方: Scripts/to-webp.sh <入力> <出力.webp> [幅（既定 1600）]
#   例: Scripts/to-webp.sh ~/Desktop/shot.png site/assets/img/grid-dark.webp
#       Scripts/to-webp.sh ~/Desktop/phone.png site/assets/img/web-list.webp 600
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <input> <output.webp> [width]" >&2
  exit 2
fi
input=$1
output=$2
width=${3:-1600}

if ! command -v cwebp >/dev/null 2>&1; then
  echo "cwebp not found; install it with: brew install webp" >&2
  exit 1
fi
case "$output" in
  *.webp) ;;
  *) echo "output must end in .webp" >&2; exit 2 ;;
esac

# Never enlarge: keep the source width when it is already narrower.
source_width=$(sips -g pixelWidth "$input" | awk '/pixelWidth/ {print $2}')
if [ -n "$source_width" ] && [ "$source_width" -lt "$width" ]; then
  width=$source_width
fi

cwebp -quiet -q 82 -alpha_q 90 -m 6 -metadata none -resize "$width" 0 "$input" -o "$output"
echo "$output ($(wc -c < "$output" | tr -d ' ') bytes, ${width}px wide)"
