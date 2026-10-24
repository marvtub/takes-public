---
name: takes-video-edit
description: "Edit a video recorded in Takes, starting from the Takes session (takes MCP): rough_cut and cut_take for the cuts, render_edit and publish_edit to build and save each version from its recipe, HyperFrames for the motion graphics over it. Start here for any video in Takes, also when the HyperFrames skills are installed. Use when the user asks to edit, cut, trim, caption, reframe (for example to 9:16), clean up the audio of, fix the words said in, add a voice-over to, or make a thumbnail for a take or a video in Takes, or asks for a new version of an edit after review comments."
---

# Takes video edit

Takes cuts the takes (`rough_cut`, `cut_take`) and builds each version of the edit from a recipe
(`render_edit`, `publish_edit`). `ffmpeg`/`ffprobe` are for stills and picture layers. Exact commands
are in `references/ffmpeg-recipes.md`. Title cards, lower thirds, animated captions and other motion
graphics are HyperFrames compositions: see [Motion graphics](#motion-graphics-hyperframes).

## The one rule

**A command that ran proves nothing about how it looks.** Text truncates, fonts fall back,
captions land late, crops cut off heads, all without an error. After any cut, crop, text or
grade change, render stills (first frame, last frame, the longest caption, the tightest crop)
and look at them with the Read tool before you call the edit done.

## Start from the Takes session

Use the `takes` MCP, not file guessing. **Follow the user's rules**: what you learned from their
comments on earlier videos. `get_session` and `next_path` give them (the `rules` key) the first
time in a chat; `get_rules area=edit,thumbnail` gives them all. A rule the user wrote (`by_user`) wins.

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
6. **Music and sound effects:** mix them into a new version of the edit with ffmpeg, under the
   voice. Takes plays only the file: it never adds a song or an effect while a video plays, so
   what the user hears is what posts. Find files with `list_music`. The Sound page's Use button
   sends you the file, and for an effect the video and second. No song asked for: suggest two
   or three from `list_music` and ask first.
7. **Find footage by meaning:** `search_media` searches the whole library on this Mac: clips by
   what they show ("walking outside", "close-up of a phone"), stills, and the words in transcripts
   ("where I talk about pricing"). Hits have `path` and, for video and speech, `at` in seconds.
   Use it for b-roll and cutaways before you ask the user to film something.

## Build and publish a version

An edit is a recipe (JSON) that Takes keeps beside each version: `edits/<name>-vN.recipe.json`. Takes
renders the recipe. You change the recipe. So a new chat, or the same chat after a week, builds the
next version from that file, not from memory.

1. **First version:** `rough_cut` gives `cut`. Call `render_edit` with
   `recipe={name, cut, frame, music, sfx, over, steps, cover}` and `wait_s=120`. Leave out what you do not need.
2. **Next version:** `render_edit base=<name> changes={...}`. Change only what the comments ask for.
   A list replaces the whole list: repeat the whole music entry when you change one value. Read
   `changed` in the result: it lists every value that changed.
3. Graphics and captions: put the composition in `_edit/<name>/`, add its render command to
   `steps`, and its output (with alpha) to `over`. Captions read `_edit/<name>/words.json`.
4. If the job is not done: `get_job id=<id> wait_s=50`. Then grab 3 to 5 frames of the render and look at them.
5. `publish_edit render=<id> note="<what the viewer notices>" replies=[...]`. It saves the version and its
   recipe, moves the posts and answers the comments. The checks already ran in the render.
6. Never mix a finished edit into a new one. Never clean the voice twice.

Times in `over`, `music` and `sfx` are seconds of the cut; a `cover` adds its 0.1 s by itself. Music and
sound effects come from `list_music` (`@library/...` paths). `get_edit_recipe` shows any version's
recipe and the versions before it.

## Cut a talking-head video

Takes makes each take ready to edit when it saves it: word times on the video clock
(`get_session` → each take's `edit_ready`). Cut takes with `rough_cut` and `cut_take` by default:
they fix the take's audio offset (0.16–0.24 s on a camera take) and its frame rate.

When you need what they cannot do (a J/L cut where sound and picture cut at different points, a
speed change, a frame cut inside a word, an effect), use your own ffmpeg. Start from `cut_take`'s
synced `_work` clip and `.wav`, or from the take with the `audio_offset_s` that `get_session` shows
(see "Audio by hand" below). Tell the user what you did.

1. **First cut:** `rough_cut` with the session (optional `takes`, `gap`). It keeps each script
   line once (the last full try) and drops false starts, stutters, ums and long pauses. It returns
   the clip, `cut` (the segments), `dropped` (each with `why`) and `missing` (script lines that no
   take has). Show the user the clip with `open_in_app` and tell them in plain words what you
   dropped and what is missing. The rough cut is only a first draft: improve it freely.
2. **Any other cut:** `cut_take` with `segments: [{take, in, out}]`, seconds of the take. To
   change the rough cut, edit its `cut` and send it to `cut_take`. A cut point inside a word moves
   to the word's edge (`moved`). The clean voice goes in when `clean_voice` is done.
3. Both write `_work/<name>-vN.mp4`, a voice-only `.wav` and a `.words.json` (word times in clip
   time). A long cut returns a job: `get_job wait_s=50` gives the same result.
4. `_work/` is a working folder. The cut you keep goes into the recipe's `cut`: `render_edit` builds
   the version (see above). Then look at stills of it.

**Slow steps run as a job.** The final ffmpeg encode, a HyperFrames render, Demucs and Whisper
take minutes: start each one with `run_job` (`cmd` with paths relative to the session, `outputs`
from `next_path`, a short `label`), never as a background Bash job or with `sleep`. If it ends
within about 2 min, wait with `get_job wait_s=50`. Else tell the user in one line what runs and
end your turn: Takes tells you when it ends, and you go on from there (stills, `check_edit`,
`open_in_app`). Quick steps (a still, an `ffprobe`) stay in Bash.

## Voice

Call `clean_voice` with `session` and `take` (optional `strength` 0–1, `loudness` `normal`
= −14 LUFS or `quiet` = −18 LUFS for a video with music). It runs in the background. When
`get_session` shows `voice.file` under the take, use that WAV as the take's audio instead of the
audio in the .mov (`cut_take` does this for you). It already has noise removal, EQ, compression and loudness. Do not compress it
again: a second compressor lifts the room echo after every word. Only trim, fade and mix it.
`render_edit` uses the clean voice. Do not process it.

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

The result of your cut goes into the recipe's `cut`. `rough_cut` and `cut_take` put each cut at a word edge, keep pauses up to `gap` (0.25 s by
default), fade 8 ms at each cut, keep the voice in sync and give a constant frame rate. What is
left for you:

1. **Read the clip's words against the script.** The clip's `.words.json` has them. A missing
   word: move that segment's `in` or `out` and run `cut_take` again.
2. **Pauses:** about 0.15–0.25 s between sentences. Keep at most one long pause for effect.
3. **Look at a frame at each cut** before you build on the clip.
4. **Audio by hand:** if you take sound out of a take yourself, add
   `-af aresample=async=1:first_pts=0`. Plain `-vn` drops the take's audio offset and puts the
   voice 5 frames early. A cleaned voice with `voice.starts_at_s` in `get_session` starts that much
   after the video: delay it by that much.

## Motion graphics (HyperFrames)

Takes installs the HyperFrames skills (HeyGen, Apache-2.0) with this one: Plugins › Skills ›
HyperFrames. A composition is an HTML file that HyperFrames renders to video, frame-exact. This
skill owns the edit; HyperFrames makes only the layers that go over it.

- **Not installed** (no `hyperframes` skill): tell the user to switch on HyperFrames in Takes ›
  Plugins › Skills, then go on with plain ffmpeg text for now. Rendering needs Node.js (`npx`).
- **Style first:** `get_library session=<session>` gives the style's tokens (colours, fonts) and its
  saved parts (title cards, lower thirds, captions). Start from a saved part when one fits. Write
  new ones in the style's tokens.
- **Where:** the composition goes in `_edit/<name>/`. Read the `hyperframes-core` skill before you
  write its HTML. For captions, read the word times from `_edit/<name>/words.json`.
- **Render with alpha** so the footage shows through: `npx hyperframes render --format mov
  --quality looks --output <file>.mov` (or `--format webm`). Put that command in the recipe's
  `steps` (`{run: [argv], cwd: "_edit/<name>", makes: [file]}`) and the file in `over`
  (`{file, at, alpha: true}`). `render_edit` runs the step and lays the layer over the cut.
- **Never open the user's screen:** `npx hyperframes preview --background --no-open`. Look at
  stills of the render, not at the Studio.
- **Keep what works:** after the user likes a part, `save_to_library` with the render, a one-line
  `note` and `source_dir` (the composition), so the next video starts from it.

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

- **Edits:** `render_edit` + `publish_edit` write `<session>/edits/<slug>-vN.mp4` and its recipe.
  `next_path kind=edit name=<slug>` gives the path for an edit you make by hand. Videos only.
- **To finish in another editor** (Resolve, Premiere, Final Cut), on the user's ask: `export_edit
  edit=<slug>-vN` writes `.fcpxml`, `.premiere.xml` and `.edl` next to the version. Tell the user
  what its `left_out` lists.
- **Thumbnails:** `next_path kind=thumbnail name=<slug>` gives `<session>/thumbnails/<slug>-vN.png`.
  For several options, add an option word to the name (`<slug>-closeup`). Never put them in `edits/`.
- **Never overwrite a version, and never write to or rename a take file.** Every change is a new
  version.
- Save the transcript of each version as `edits/<slug>-vN.words.json`.
- Keep scratch files (cut lists, intermediate WAVs) in a temp folder, not in the session.
- **Cover:** if the post's front matter (`posts/linkedin.md`) has `cover` set, put that image in the
  recipe's `cover`: every new version starts with it as its first 0.1 s.

## Thumbnails

Start from `stills/`. Otherwise pull candidate frames from the edit (a contact sheet helps) and
pick a sharp frame with eyes open and a natural expression, never mid-word. Add at most a short
title in the style's fonts. Look at the result at small size, the way a feed shows it. Offer
several options when the user did not ask for one specific look.

## After a new version

1. `publish_edit` puts the new version on the posts that showed the one before (a version the user
   picked stays) and opens it in the app. For a post of another shape, `set_post` with `media`:
   `platform: "vertical"` for 9:16, `platform: "youtube"` for a long 16:9 edit. Only change `media`;
   keep the user's post text.
2. `render_edit` runs `check_edit` on every render: it compares the edit with the take (sound,
   picture, sync, words and past fixes). Fix every problem before you publish. Run `check_edit` on
   an edit you made by hand. Do not judge sound by listening with a model: the checks measure it.
   With a Gemini key, Gemini also watches each version next to the user's rules (about 5 cents);
   `publish_edit` and `check_edit` return it as `review`. Its problems are a view, not measurements:
   look at the frame of each one, then fix what is real in the next version. Without a key, `review`
   gives a frame sheet: read it and check each frame against the rules yourself.
3. For an edit you made by hand: `open_in_app` with the new file's path, once per finished version.
   It never takes focus.
4. Never open files or apps on the user's screen yourself (no `open`, no QuickTime).

## Review comments

The user reviews edits in Takes with comments on a time range and an area of the frame, on an
image area, or on selected script text. `get_session` shows `open_comments`.

1. `get_comments` returns each comment with `when` (start/end seconds), `area`, `said` (the words
   there, from `<stem>.words.json`) and a `frame` PNG with the area outlined. **Read every frame
   PNG.** The outline shows what "this" means.
2. Fix all of them in one new version: `render_edit base=<name> changes={...}`, then
   `publish_edit replies=[{id, text, lesson}]` answers them with the new version.
3. For an edit made by hand, one `reply_comment` call: `replies: [{id, text, resolve: true, fixed_in, fixed_at, lesson}]`.
   `fixed_in` is the new file, `fixed_at` the second where the fix shows. One line of text each.
   If a comment is unclear, ask a question and leave it open.
   **`lesson`** says what the comment taught: the id of a rule from `get_rules` that already
   covers it (the same mistake again), `"new"` with `rule: {area, text}` when it holds for the
   next videos too, or `"one-off"`. Keep rules few and short (one sentence, 10 per area; longer
   words go in `details`): sharpen a rule with `set_rule` before you add one. When an area is
   full, give the new rule `merge_into` (the closest rule) and `merged` (one sentence for both):
   the user approves the merge on the Feedback board. When a rule comes back again and a number can test it
   (loudness, peak, pauses, length), give it a `check` with `set_rule`.
4. Script comments: fix with `update_session` or `update_variant`, then reply.

## When it is live

When the user says the video is posted, call `set_published` with `session`, `platform` and
`url`, once per platform. Do not delete session files yourself: the user cleans up in the app.

## Report back

- The path of the new file in `edits/` and its length.
- That caption wording needs the user's check: speech recognition can mishear words.
- Any text you added on screen that the user did not say.
