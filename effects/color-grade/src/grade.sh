#!/bin/sh
# Colour grade: makes the two clips the wipe needs, from one clip of the moment.
#   sh grade.sh <clip> [out_dir] [WxH]
# Writes out_dir/after.mp4 (the cinematic grade) and out_dir/before.mp4 (a flat, log-like look),
# both at WxH (the edit's frame size, default 1080x1920), no sound. BEFORE=source keeps the clip as it is for the before side.
# Only ffmpeg is needed. The grade is GRADE below; cinematic.cube is the same grade as a 3D LUT
# (CC0) for Resolve, Final Cut or ffmpeg lut3d. The vignette is not in the LUT.
set -eu
IN=${1:?usage: sh grade.sh <clip> [out_dir] [WxH]}
OUT=${2:-.}
SIZE=${3:-1080x1920}
W=${SIZE%x*}; H=${SIZE#*x}

# Cinematic: more contrast, cool shadows, warm highlights, soft roll-off at both ends.
GRADE="eq=contrast=1.1:saturation=1.04,colorbalance=rs=-0.06:gs=0.0:bs=0.08:rm=0.01:bm=-0.01:rh=0.03:gh=0.01:bh=-0.04,curves=master='0/0.02 0.25/0.21 0.5/0.5 0.78/0.8 1/0.97'"
VIGNETTE="vignette=angle=0.45"
# Flat: lifted blacks, lowered whites, half the colour. Looks like log footage before a grade.
FLAT="curves=master='0/0.14 0.5/0.52 1/0.84',eq=saturation=0.5"

FIT="scale=$W:$H:force_original_aspect_ratio=increase,crop=$W:$H,setsar=1"
ENC="-an -c:v libx264 -crf 14 -preset medium -pix_fmt yuv420p -movflags +faststart"
mkdir -p "$OUT"
ffmpeg -nostdin -v error -y -i "$IN" -vf "$FIT,$GRADE,$VIGNETTE" $ENC "$OUT/after.mp4"
if [ "${BEFORE:-flat}" = source ]; then
  ffmpeg -nostdin -v error -y -i "$IN" -vf "$FIT" $ENC "$OUT/before.mp4"
else
  ffmpeg -nostdin -v error -y -i "$IN" -vf "$FIT,$FLAT" $ENC "$OUT/before.mp4"
fi
echo "made $OUT/before.mp4 and $OUT/after.mp4"
