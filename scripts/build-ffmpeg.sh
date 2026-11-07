#!/bin/bash
# 앱에 넣을 최소 LGPL ffmpeg를 소스에서 빌드한다. 결과: App/Vendor/bin/ffmpeg (git 무시).
# 이미 있으면 다시 빌드하지 않는다. 다시 빌드하려면 App/Vendor/를 지운다.
set -euo pipefail

VERSION="7.1.5"
SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/Vendor/bin/ffmpeg"

if [[ -x "$OUT" ]]; then
    echo "이미 있어요: $OUT"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jamak-ffmpeg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "ffmpeg ${VERSION} 받는 중"
curl -fsSL --retry 3 --retry-all-errors "$URL" -o "$WORK/ffmpeg.tar.xz"
echo "${SHA256}  $WORK/ffmpeg.tar.xz" | shasum -a 256 -c -
mkdir "$WORK/src"
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK/src" --strip-components 1

cd "$WORK/src"
# mov_text 코덱의 configure 구성요소 이름은 movtext다(mov_text로 쓰면 조용히 빠진다).
# hevc/h264 디코더는 디코딩용이 아니다. mkv에는 DTS가 없어 ffmpeg가 B-프레임 지연을 알아야 DTS를 만드는데,
# 그 값은 디코더가 있어야 채워진다. 없으면 mkv→mp4 복사에서 프레임 시간이 뭉개져 재생이 끊긴다.
./configure \
    --disable-everything \
    --disable-gpl \
    --disable-nonfree \
    --enable-static \
    --disable-shared \
    --disable-network \
    --disable-autodetect \
    --disable-doc \
    --arch=arm64 \
    --extra-cflags="-mmacosx-version-min=14.0" \
    --extra-ldflags="-mmacosx-version-min=14.0" \
    --enable-protocol=file,pipe \
    --enable-demuxer=matroska,mov,srt \
    --enable-muxer=mp4,mov,matroska,srt \
    --enable-parser=h264,hevc,aac,ac3,dca,opus,flac \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
    --enable-decoder=hevc,h264,ac3,eac3,dca,truehd,flac,opus,vorbis,mp3,aac,pcm_s16le,pcm_s24le,srt,subrip,ass,movtext \
    --enable-encoder=aac,srt,subrip,movtext \
    --enable-filter=aresample,aformat,anull,null

make -j"$(sysctl -n hw.ncpu)" ffmpeg

# 끝까지 성공했을 때만 결과가 생기게 임시 이름으로 만든 뒤 옮긴다(반쯤 만든 파일을 "이미 있음"으로 보지 않게).
mkdir -p "$(dirname "$OUT")"
cp ffmpeg "$OUT.partial"
strip "$OUT.partial"
mv -f "$OUT.partial" "$OUT"
echo "완료: $OUT"
