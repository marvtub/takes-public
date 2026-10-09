---
name: takes-video-edit
description: Edit a video recorded in Takes with ffmpeg and Whisper, starting from the Takes session (takes MCP). Use when the user asks to edit, cut, trim, caption, reframe (for example to 9:16), clean up the audio of, fix the words said in, add a voice-over to, or make a thumbnail for a take or a video in Takes, or asks for a new version of an edit after review comments.
---

# Takes video edit

The tools are `ffmpeg`/`ffprobe` and the `openai-whisper` CLI (`pip install openai-whisper`).
Exact commands are in `references/ffmpeg-recipes.md`. Other tools (for example HyperFrames for
motion graphics) are optional. Use them only if the user has them and asks for that kind of work.

## The one rule

**A command that ran proves nothing about how it looks.** Text truncates, fonts fall back,
captions land late, crops cut off heads, all without an error. After any cut, crop, text or
grade change, render stills (first frame, last frame, the longest caption, the tightest crop)
and look at them with the Read tool before you call the edit done.

## Start from the Takes session

Use the `takes` MCP, not file guessing.

1. `get_session` gives the script, every take (file path, duration, `keeper` star, the script
   variant and hook it was read with), every asset, the folder rules, `warnings` and
   `open_comments`. Fix any `warnings` about files in the wrong place.
2. **Edit the keeper** (the starred take). No star: ask which take. Do not pick one yourself.
   A recording made outside Takes (phone, QuickTime, a download): add it with `import_take`
   first. Never edit `session.json` by hand.
3. **Camera + screen takes:** both files of one take share a number. Both carry the mic, so
   line them up by their audio if they drift.
4. **`stills/` and `assets/` belong to the user.** Read them, never write there. `stills/` holds
   frames the user saved from a take: try them first for the thumbnail.
5. **Style:** call `get_library session=<session>` before you design captions, a thumbnail or a
   title. Use its `tokens` (colours, type) and `template` if the user picked a style. No style:
   use plain, readable defaults (see below).
6. **Music and sound effects:** `get_session` returns the user's picks as `music` (`path`,
   `start`, `volume`) and `sfx` (cues with `at` and `volume` on a take or an edit). Use them as
   given. A cue on a raw take is a moment of the take: map it through your cut list. No pick:
   ask, or suggest options from `list_music`. Call `set_music` or `set_sfx` only when the user
   agrees.
7. **Find footage by meaning:** `search_media` searches the whole library on this Mac: clips by
   what they show ("walking outside", "close-up of a phone"), stills, and the words in transcripts
   ("where I talk about pricing"). Hits have `path` and, for video and speech, `at` in seconds.
   Use it for b-roll and cutaways before you ask the user to film something.

## Cut a talking-head video

Every take has a transcript with word times (`get_session` → each take's `said` and
`transcript`, a `.words.json` file). Cut at word edges with ffmpeg (below): start a little before
the first word, end a little after the last. Write each version to `edits/<name>-vN.mp4`, then
look at stills of it.

## Voice

Call `clean_voice` with `session` and `take` (optional `strength` 0–1, `loudness` `normal`
= −14 LUFS or `quiet` = −18 LUFS for a video with music). It runs in the background. When
`get_session` shows `voice.file` under the take, use that WAV as the take's audio instead of the
audio in the .mov. It already has noise removal, EQ, compression and loudness. Do not compress it
again: a second compressor lifts the room echo after every word. Only trim, fade and mix it.

Keep every intermediate audio file as float WAV (`pcm_f32le`). Integer WAVs clip peaks over
0 dBFS, which sounds like clicks.

## New words, voice-over, other voices (ElevenLabs)

These tools need an ElevenLabs key in Takes › Plugins › Voices. When a tool says there is no key,
tell the user to open that page. Each call costs ElevenLabs characters (about one per letter), so
make one call per ask.

- **Fix what was said:** `fix_words` with `take` (or `file`), `old` (the words exactly as said; the
  transcript has them) and `new`. Takes says the new words in the voice, using the sentences around
  them so the tone matches. It cuts them in at the word edges, using the take's cleaned voice when
  there is one. When the new words fit the old time (0.8–1.25×), the result is the same length as
  the take, with a `.wav` and an `.mp4`, so your cut list still holds. If they do not fit, there is
  only a WAV, and the result says how far everything after the fix moved. The lips do not move
  with the new words: tell the user when the fix is on camera, and offer b-roll over it.
- **Voice-over:** `voiceover` reads `text`, or by default `script.md`. It writes
  `generated/<name>-vN.wav` at −14 LUFS. Treat it like a cleaned voice: trim, fade and mix it, but
  do not compress it again.
- **Another voice:** `change_voice` says a take or a part of it (`start`/`end`) again in another
  voice, with the same words and timing.
- **Voices:** `voice` takes a name or the start of one. Leave it out to use the default voice the
  user picked. `voices` lists the voices, and `voices search=...` finds voices in the ElevenLabs
  library. `design_voice` makes three samples from a description for the user to choose from.

## Cut

1. **Transcribe** the voice with Whisper word timestamps. Save it next to the video as
   `<stem>.words.json`: Takes uses it to quote what was said at each review comment.
2. **Find fillers.** Whisper hides "um" and "uh" by default. Pass an `--initial_prompt` full of
   fillers (see recipes) and they show up.
3. **Find restarts.** Look for repeated phrases ("I just saw… I just saw that"). Keep the last,
   clean attempt. Transcribe each kept piece again on its own: a full transcript often merges
   repeats.
4. **Place every cut in silence.** Whisper word times can be off by 0.3 s. Find the real gap on
   a short loudness envelope (`silencedetect`, or 20–40 ms RMS) and cut inside it.
5. **Never clip a word end.** A final t, k, p or d releases after Whisper's end time. Leave about
   0.1–0.2 s after the last word of a sentence. Quiet words can sit near the noise floor: after
   each recut, read the new transcript against the script for missing words.
6. **Pauses:** about 0.15–0.25 s between sentences, shorter inside a sentence. Keep at most one
   long pause for effect.
7. **Start on the first word** (no breath before it) and end soon after the last word.
8. **Fades:** 10–20 ms audio fade at each cut so it does not click.
9. **Sync:** camera files can have an audio stream that starts later than the video. Read the
   stream `start_time` with `ffprobe` and shift by it. Variable-frame-rate files drift when cut
   by time: make a constant-frame-rate copy first and cut by frame.

## Reframe, grade, captions

- **9:16 reframe:** crop around the face, not the frame centre. Keep head and shoulders in every
  frame, never cut the top of the head or the chin. Check stills at several points in the take.
  A 9:16 cut gets its own name (`<slug>-vertical`).
- **Grade:** stay close to the raw footage. Small contrast and saturation changes at most.
- **Captions:** build them from the word times of the *final* edit, not the raw take. Short lines
  (2–5 words), sentence case, a bold sans-serif font, white with a dark outline or shadow, in the
  lower third and clear of the face. Each line appears on its first word. Burn them with the
  `subtitles` filter, or deliver an `.srt` if the user wants platform captions.
- **Loudness:** final mix at about −14 LUFS, true peak at or below −1 dBTP. Music sits well under
  the voice and ducks while the user talks.
- **Final mux:** add `-map_chapters -1 -dn`. Some music files carry chapter tracks that make the
  video report the wrong length.

Order that works: cut, then reframe, then grade, then audio, then captions.

## Where files go

**Always get the path from `next_path`.** It picks the folder and the next version number.

- **Edits:** `next_path kind=edit name=<slug>` gives `<session>/edits/<slug>-vN.mp4`. Videos only.
- **Thumbnails:** `next_path kind=thumbnail name=<slug>` gives `<session>/thumbnails/<slug>-vN.png`.
  For several options, add an option word to the name (`<slug>-closeup`). Never put them in `edits/`.
- **Never overwrite a version, and never write to or rename a take file.** Every change is a new
  version.
- Save the transcript of each version as `edits/<slug>-vN.words.json`.
- Keep scratch files (cut lists, intermediate WAVs) in a temp folder, not in the session.
- **Cover:** if the post's front matter (`posts/linkedin.md`) has `cover` set, every new edit
  starts with that image as its first 0.1 s, and `cover_video` points at the new file. See
  recipes.

## Thumbnails

Start from `stills/`. Otherwise pull candidate frames from the edit (a contact sheet helps) and
pick a sharp frame with eyes open and a natural expression, never mid-word. Add at most a short
title in the style's fonts. Look at the result at small size, the way a feed shows it. Offer
several options when the user did not ask for one specific look.

## After a new version

1. `set_post` with `media` set to the new edit, for each post of that shape: `platform:
   "vertical"` for 9:16, `platform: "youtube"` for a long 16:9 edit, and the LinkedIn or X post as
   usual. Only change `media`; keep the user's post text.
2. `open_in_app` with the new file's path, once per finished version. It never takes focus.
3. Never open files or apps on the user's screen yourself (no `open`, no QuickTime).

## Review comments

The user reviews edits in Takes with comments on a time range and an area of the frame, on an
image area, or on selected script text. `get_session` shows `open_comments`.

1. `get_comments` returns each comment with `when` (start/end seconds), `area`, `said` (the words
   there, from `<stem>.words.json`) and a `frame` PNG with the area outlined. **Read every frame
   PNG.** The outline shows what "this" means.
2. Fix all of them in one new version, at the path from `next_path`.
3. One `reply_comment` call: `replies: [{id, text, resolve: true, fixed_in, fixed_at}]`.
   `fixed_in` is the new file, `fixed_at` the second where the fix shows. One line of text each.
   If a comment is unclear, ask a question and leave it open.
4. Script comments: fix with `update_session` or `update_variant`, then reply.

## When it is live

When the user says the video is posted, call `set_published` with `session`, `platform` and
`url`, once per platform. Do not delete session files yourself: the user cleans up in the app.

## Report back

- The path of the new file in `edits/` and its length.
- That caption wording needs the user's check: Whisper can mishear words.
- Any text you added on screen that the user did not say.
