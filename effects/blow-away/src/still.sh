#!/bin/zsh
# Blow away prep: ./still.sh <this folder> <seconds>
# Saves the speaker's cutout at the moment the dust starts as person-still.png (the body that blows away).
cd "$1" && ffmpeg -v error -y -c:v libvpx-vp9 -ss "$2" -i person.webm -frames:v 1 -pix_fmt rgba person-still.png && echo "person-still.png at $2 s"
