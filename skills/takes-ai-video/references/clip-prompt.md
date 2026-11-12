# Clip prompt

One clip, one clear action. Write it in this order. Seedance names the references by their order:
`@image1`, `@image2`, `@video1`, `@audio1`. On Replicate the names are `[Image1]`, `[Video1]`, `[Audio1]`.

```
Duration: [X] seconds.

Audio: [every sound. Speech: who speaks, the language, how, and the words in { }, or "speaks the
line in @audio1". Effects in < >. Music in ( ), or "No background music". "No subtitles."]

Context: [What each reference is: "@image1 is the first frame", "@image2 is the character sheet:
the same person", "@image3 is the place and its light".
Who: made-up adult, age range, build, skin, face, hair, clothes with colours, fabric and fit.
What they do. Where: place, time of day, weather, the light source and its direction, the main
props and where they stand.
Look: real live-action footage on a cinema camera, natural lens, true colour, skin with pores and
small marks, fabric that moves, correct physics and anatomy, real hands, no beauty filter, no
CGI, drawn or plastic look.]

Movement and editing:
0-[X]s: [shot size, where the camera is and how it moves (static, slow push in, handheld follow,
pan, tilt), what the person does step by step, how the face changes, how the frame looks at the end.]
[X]-[Y]s: [the next beat. Say "one continuous take" or "cut to".]
[Y]-[Z]s: [the last beat. End on a settled frame.]
Keep [the person, the number of people, clothes, props and light] the same throughout. No text,
no logos, no watermarks, no other people.
```

Outside the prompt: the references in the order the prompt names them, the length, the shape
(`aspect_ratio`) and the resolution.

## Write a check list with every prompt

Two to four things to look for in this clip, and one fix if it goes wrong. For example:

- The face at 0 s and at the end against the sheet. Fix: add an `end_image` with the face.
- One person only, in every frame.
- The hand on the mug: five fingers, the mug stays solid. Fix: a wider shot, or a smaller action.
- Lips on "{the line}". Fix: a shorter line, the face larger in the frame.
- No music, no subtitles, no letters on the wall.

## What makes a prompt fail

- Two actions in one clip. Split it.
- "Cinematic", "beautiful", "stunning" with no light source named. Name the light.
- Camera move and subject move both large. Keep one of them small.
- A cut inside a short clip. One take per clip; cut in the edit.
