---
name: takes-ai-video
description: Make AI footage that looks real, in few tries. Use when the user asks for an AI video, an AI clip or AI b-roll, asks to generate or animate a storyboard shot, wants a made-up character or scene, or says a generated clip "looks fake" or "looks AI". Plans the look, makes a place still and a character sheet with make_image, makes each spoken line with voiceover, then one clip per shot with higgsfield or replicate (Seedance 2.5), checks it, and adds sound effects and a grade in the edit.
---

# Takes AI video

A clip looks fake when the model had to guess. Each guess comes out generic: flat light, a tidy
room, a perfect face, floating props, a voice that does not fit. So decide these things first,
show the model pictures and sound of them, and ask for one small action per clip. That also saves
money: a clip costs much more than a still or a voice line.

All files go through the `takes` MCP and land in `<session>/generated/`.

## What the model guesses, and what to give it

| It guesses | Give it |
|---|---|
| Light | The source, its direction and the time of day: "low afternoon sun through blinds from the left", "hard overhead office tubes". The same words in every prompt. |
| Place | A room someone lives in: named objects, wear, one thing out of place. Not a tidy showroom. |
| Person | An ordinary person: uneven skin, pores, a little asymmetry, hair not quite in place, clothes with creases. A character sheet holds them the same in every shot. |
| Physics | One clear action per clip, written step by step, with what each object does ("she lifts the mug, the coffee moves, she sets it down on the coaster"). |
| Sound | The voice line made first and passed in. Effects and room tone added in the edit. |
| Finish | A grade that matches every clip to one frame. A grade cannot fix a wrong hand or a face that changed. |

## Steps

1. **Plan the look (5 minutes, in the chat).** Write six lines and show them to the user: who
   (age, build, face, hair, clothes), how they talk, where, time of day, light, mood. Ask only
   for what you cannot decide. These exact words go into every prompt after this.
2. **Place still.** `make_image` of the empty place in that light, in the video's shape
   (`format`). This is the **anchor frame**: every later still and clip gets it as a reference,
   so the light and colours stay the same.
3. **Character sheet.** One 16:9 image with two views of the same person on white: a large face
   close-up and the whole body. Fill the template in `references/character-sheet.md` and call
   `make_image`. The user in the video: pass a still of them (`stills/` or a keeper frame) as the
   first image and keep their face. Show the sheet and the place to the user before any clip.
4. **A still per shot, when the video has more than one shot.** For each new angle make the first
   frame with `make_image images=[anchor, sheet]` and the shot's framing. Let the user approve
   it. Do not start a shot from the last frame of the clip before: the angle never changes then.
   A face hidden at the start (seen from behind) comes back as a new face: make an end still
   with the real face and pass it as `end_image`.
5. **Voice line first.** A person who speaks: `voices` (search by gender, age, accent) to pick a
   voice, once per character, then `voiceover text=<the line> voice=<it>`. The same voice in
   every shot. The line must be shorter than the clip.
6. **The clip.** Write the prompt from `references/clip-prompt.md`: length, every sound, who and
   where in the plan's words, then the action second by second, then what must stay the same.
   - `higgsfield`: always `params {mode: "omni_reference"}`. `start_image=<the shot still>`,
     `images=[sheet, anchor]`, and `audio=<the voice wav>` with "speaks the line in @audio1" in
     the prompt.
   - `replicate` (Seedance 2.5, tested 2026-11-09): `params {reference_images: [anchor],
     reference_audios: [voice wav]}`, named `[Image1]` and `[Audio1]` in the prompt, not
     `@image1`. A voice file needs at least one reference image. A first frame (`image`) cannot
     go with references. **It refuses every realistic face picture**, as a reference and as a
     first frame ("flagged as sensitive", nothing made): pass the place still only and write
     the person in words from the plan. A face that must stay the same across shots needs
     `higgsfield`. Other models: call `replicate_model` first.
   - The model speaks the line again in a voice like the file; it does not copy the file. The
     timing differs, so check the lips against the clip's own sound, not the wav.
   - Say the price first (`cost: true` on `higgsfield` is free). Make a cheap draft while you
     look for the shot: 480p, or 720p. Make the full size only of the one that passed.
   - One job per ask. With `shot=<id>` the clip lands on the storyboard shot.
7. **Check before you show it.** Pull frames (start, middle, end) and look: the same face and
   clothes as the sheet, the right number of people, hands and fingers, props that stay solid,
   lips on the words, no letters or subtitles, no music that nobody asked for. Each prompt ends
   with its own short check list: use it. Wrong? Change one thing in the prompt and say what.
   After two bad tries, make the action smaller or split the shot. Do not send the same prompt
   again.
8. **Sound.** `sfx_sounds`, then `make_sfx` or `design_sfx` for each effect, placed on its
   frame with `render_edit` `sfx`. Add quiet room tone under a scene. A clip whose voice came
   out wrong: lay the `voiceover` wav over it in the edit.
9. **Finish in the edit.** Fix wrong clips first. Then match exposure, white balance and
   saturation of every clip to the anchor frame. A light film grain, a look-up table or a
   vignette only when the user wants that look: ask first. Run `check_edit` on the edit.

## Rules

- Images come from `make_image`, never from `higgsfield`.
- Never ask for words in the frame. Text comes out garbled; add it in the edit.
- "No subtitles" and "No background music" go in every clip prompt unless the user wants them.
- Made-up people only, unless the user gives their own picture. No real person's name or brand.
- Tell the user what each paid step cost and what is left.

Source: the method follows ElevenCreative's guide "Why your AI video looks fake (and how to fix
it)" (Nov 2026). The two templates are rewritten for the Takes tools.
