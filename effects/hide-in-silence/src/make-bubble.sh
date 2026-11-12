#!/bin/sh
# The camera as a round bubble in a corner, on a see-through frame: the picture layer that render_edit's
# hide_in_silence fades out in the pauses. ProRes 4444 with alpha.
#
#   sh make-bubble.sh <camera.mov> <out.mov> <W> <H> <fps> <start> <length> <x> <y> <side> [size] [corner]
#
# W x H: the edit's frame. start, length: seconds of the camera file. x, y, side: the square of the camera
# (its pixels) that fills the bubble, the face in its middle. size: the bubble's width as a share of the
# frame's shorter side (default 0.3). corner: br, bl, tr or tl (default br).
set -e
cam=$1 out=$2 W=$3 H=$4 fps=$5 start=$6 len=$7 x=$8 y=$9 side=${10} size=${11:-0.3} corner=${12:-br}
short=$(( W < H ? W : H ))
d=$(awk -v s="$short" -v k="$size" 'BEGIN { d = int(s * k / 2) * 2; print d }')
m=$(( short / 24 ))
case $corner in
  br) ox=$(( W - d - m )) oy=$(( H - d - m )) ;;
  bl) ox=$m oy=$(( H - d - m )) ;;
  tr) ox=$(( W - d - m )) oy=$m ;;
  tl) ox=$m oy=$m ;;
  *) echo "corner is br, bl, tr or tl" >&2; exit 2 ;;
esac
r=$(( d / 2 ))
ffmpeg -nostdin -v error -y -ss "$start" -t "$len" -i "$cam" -filter_complex \
  "[0:v]crop=$side:$side:$x:$y,scale=$d:$d,fps=$fps,format=yuva444p,geq=lum='p(X,Y)':cb='p(X,Y)':cr='p(X,Y)':a='255*clip($r-hypot(X-$r+0.5,Y-$r+0.5)+0.5,0,1)'[c];color=c=black@0.0:s=${W}x${H}:r=$fps,format=yuva444p[bg];[bg][c]overlay=$ox:$oy:shortest=1:format=auto" \
  -an -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le "$out"
