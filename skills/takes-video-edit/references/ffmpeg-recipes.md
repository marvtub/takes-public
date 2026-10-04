# ffmpeg and Whisper recipes

Replace the CAPS words. `IN.mov` is the keeper take, `VOICE.wav` the `clean_voice` file (or the
take's own audio), `OUT.mp4` the path from `next_path`.

## Inspect

```bash
# Streams, frame rate, audio start offset (start_time), duration
ffprobe -v error -show_entries stream=index,codec_type,r_frame_rate,avg_frame_rate,start_time,width,height \
  -show_entries format=duration -of json IN.mov
```

If `r_frame_rate` and `avg_frame_rate` differ, the file is variable frame rate. Make a CFR copy
before you cut:

```bash
ffmpeg -i IN.mov -vf fps=30 -c:v libx264 -crf 16 -preset fast -c:a copy cfr.mp4
```

## Transcribe with word times

```bash
whisper VOICE.wav --model small.en --language en --word_timestamps True \
  --output_format json --output_dir work \
  --initial_prompt "Umm, let me think like, hmm... Okay, uh, here's what I'm, like, uh, thinking. Um."
mv work/VOICE.json SESSION/edits/SLUG-vN.words.json   # after the final render: transcribe the edit itself
```

Use a larger model (`medium.en`, `large-v3`) for hard audio, or `--language` for other languages.

## Find silences

```bash
ffmpeg -i VOICE.wav -af silencedetect=noise=-40dB:d=0.12 -f null - 2>&1 | grep silence_
```

Set `noise` a few dB above the room's noise floor. Cut in the middle of a gap, or at its edges
plus a small pad. Check quiet words did not fall inside a "silence".

## Cut and join

Keep a list of (start, end) pieces. Build one filter graph so video and audio stay in sync:

```bash
ffmpeg -i cfr.mp4 -i VOICE.wav -filter_complex "
[0:v]trim=start=1.20:end=4.85,setpts=PTS-STARTPTS[v0];
[1:a]atrim=start=1.20:end=4.85,asetpts=PTS-STARTPTS,afade=t=in:d=0.015,afade=t=out:st=3.635:d=0.015[a0];
[0:v]trim=start=5.40:end=9.10,setpts=PTS-STARTPTS[v1];
[1:a]atrim=start=5.40:end=9.10,asetpts=PTS-STARTPTS,afade=t=in:d=0.015,afade=t=out:st=3.685:d=0.015[a1];
[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]" \
  -map "[v]" -map "[a]" -c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p \
  -c:a pcm_f32le cut.mov
```

If the take's audio starts later than its video (`start_time` of the audio stream > 0), shift the
picture: trim the video at `start + OFFSET` for each piece, or the lips run late.
A script that writes this graph from a cut list is easier than editing it by hand.

## 9:16 reframe

```bash
# 1920x1080 source -> 1080x1920. X = left edge of the crop, centred on the face.
ffmpeg -i cut.mov -vf "crop=ih*9/16:ih:X:0,scale=1080:1920,setsar=1" -c:a copy vertical.mov
```

Find X from stills (`ffmpeg -ss T -i cut.mov -frames:v 1 s.png`) at several points. If the person
moves a lot, split into pieces with their own X, or use a face tracker to build a smooth path.

## Grade (light)

```bash
-vf "eq=contrast=1.03:saturation=1.03"
```

## Captions

Write an `.srt` from the final edit's word times (2–5 words per line). Then:

```bash
ffmpeg -i vertical.mov -vf "subtitles=caps.srt:force_style='FontName=Helvetica Neue,Bold=1,FontSize=16,\
PrimaryColour=&H00FFFFFF,OutlineColour=&H80000000,BorderStyle=1,Outline=2,Shadow=0,Alignment=2,MarginV=180'" \
  -c:a copy captioned.mov
```

`FontSize` and `MarginV` scale with the video height. Render a still of the longest line and check
it fits inside the frame with a margin.

## Music under the voice and loudness

```bash
ffmpeg -i captioned.mov -ss SONG_START -i SONG.mp3 -filter_complex "
[1:a]volume=0.15,aformat=sample_rates=48000:channel_layouts=stereo[m];
[0:a]aformat=sample_rates=48000:channel_layouts=stereo,asplit[voice][key];
[m][key]sidechaincompress=threshold=0.03:ratio=6:attack=20:release=300[duck];
[voice][duck]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-14:TP=-1.5:LRA=11[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -ar 48000 \
  -map_chapters -1 -dn -movflags +faststart OUT.mp4
```

Use the user's `music.start` and `music.volume` from `get_session` when set. Without music, run
only `loudnorm` on the voice. Check the result:

```bash
ffmpeg -i OUT.mp4 -af ebur128=peak=true -f null - 2>&1 | tail -12
```

## Sound effects

Place each cue with `adelay` (milliseconds) and mix it in. Many effect files start with a short
silence: measure where the sound really starts (`silencedetect`) and subtract it, or the effect
lands late.

## Stills to look at

```bash
ffmpeg -ss 0 -i OUT.mp4 -frames:v 1 work/first.png
ffmpeg -sseof -0.1 -i OUT.mp4 -frames:v 1 work/last.png
ffmpeg -i OUT.mp4 -vf "fps=1/3,scale=360:-1,tile=4x3" -frames:v 1 work/sheet.png   # contact sheet
```

## Thumbnail with a title

```bash
ffmpeg -i FRAME.png -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='TITLE':\
fontsize=h/9:fontcolor=white:borderw=6:bordercolor=black:x=(w-tw)/2:y=h*0.08" THUMB.png
```

## Cover (first 0.1 s)

When `posts/linkedin.md` front matter has `cover`, prepend it to each new edit. Use the edit's
width W, height H and frame rate FPS:

```bash
ffmpeg -i EDIT.mp4 -loop 1 -framerate FPS -t 0.1 -i COVER.png -f lavfi -t 0.1 -i anullsrc=r=48000:cl=stereo \
  -filter_complex "[1:v]scale=W:H:force_original_aspect_ratio=increase,crop=W:H,setsar=1,fps=FPS,format=yuv420p[c];\
[0:v]setsar=1,fps=FPS,format=yuv420p[v];[2:a]aformat=sample_rates=48000:channel_layouts=stereo[s];\
[0:a]aformat=sample_rates=48000:channel_layouts=stereo[a];[c][s][v][a]concat=n=2:v=1:a=1[ov][oa]" \
  -map "[ov]" -map "[oa]" -c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p -c:a aac -b:a 192k \
  -movflags +faststart OUT.mp4
```

Then set `cover_video` in that front matter to the new file.
