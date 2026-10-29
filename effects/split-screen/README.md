# Split screen

## What it does

The speaker shot starts full frame. Then the frame opens into two halves. The top half keeps the speaker. The bottom half shows the screen recording of the same moment (or any b-roll clip). Each half has rounded corners, a dark gutter around it, and a small label chip (for example "Me" and "Notes"). Then the halves close and the shot returns to full frame.

The speaker is made smaller in the half (`CAM.scale`), so the whole head fits with some room above it. A blurred copy of the same shot, stretched to the width of the half, fills the sides, and the sharp shot fades into it.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `data-width`, `data-height` | The size of the edit in px, on `#root`. 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) and 1920x1080 (16:9) all work. The layout follows the shape (see below) |
| `SPLIT.ratio` | The share of the height for the top half (in 16:9, of the width for the left half). `0.5` = equal halves |
| `SPLIT.top` | `"speaker"` or `"screen"`: the half that goes on top (in 16:9, on the left) |
| `SPLIT.gutter`, `SPLIT.gap`, `SPLIT.radius` | The dark edge around the halves, the space between them, and the corner radius (px) |
| `CAM` | One set per shape: `tall` (9:16), `"4:5"`, `square` (1:1), `wide` (16:9) |
| `CAM.<shape>.scale` | The size of the speaker in the half (1 = full size). In 9:16 about 0.68 for a close-up, 0.85 for a wide shot. In 16:9 the speaker always fills the height of its half |
| `CAM.<shape>.y` | The row of `footage.mp4` (px, 0 to its height) that goes in the middle of the speaker half. Put it a little below the chin |
| `CAM.wide.x` | 16:9 only. The column of `footage.mp4` (0 to 1) that goes in the middle of the speaker half: the face |
| `SCREEN.fit` | `"cover"` fills the half with a part of the screen. `"contain"` shows the whole clip on a blurred copy of itself |
| `SCREEN.aspect` | The width / height of `screen.mp4` (from `ffprobe`). The layout needs it before the clip loads |
| `SCREEN.x`, `SCREEN.y`, `SCREEN.show` | Cover only. The point of the clip (0 to 1) that goes in the middle of the half, and the share of the clip's width that fills the half (`1` = the full width). `show` is set per shape |
| `LABELS` | The chip text for each half. `""` hides a chip |
| `AT` | When the split opens (`split`), and when the frame starts to return (`back`), in seconds of `footage.mp4` |
| `--accent` in `:root` | The colour of the chip dots |

The video is as long as `footage.mp4`. Keep `AT.back` 1 s or more before its end.

**Each shape.** 9:16, 4:5 and 1:1 split top and bottom. 9:16 is the original. In 4:5 and 1:1 the halves are wide and short, so the speaker is a little larger (`scale` 0.78 and 0.75) and the screen half shows a little more of the width (`show` 0.6 and 0.7). 16:9 splits side by side: the speaker on the left, filling the height of the half, and the screen on the right, coming in from the right edge.

**Why cover is the default.** A full Mac screen is about 3456 px wide. In a 1040 px half, the whole screen makes text about one third of its real size. That is too small to read on a phone. Cover shows only the part that matters (one window or one column) at about its real size, so the text stays readable. Use `"contain"` when the whole picture matters more than the text: a phone recording, a slide, a wide b-roll shot.

Look at a frame of the split: the whole head must be in the half, with some room above the hair. If the hair touches the top, make `scale` smaller or `y` larger for that shape. If the footage itself has little room above the head, the half cannot add any.

## How to make it for a video

The composition needs two clips of the same moment. The render is a full-frame layer, like Glass graph.

1. Pick the cut time `T` where the effect starts and its length `D` (5 to 6 s is typical). The window must be inside one entry of the recipe's `cut`. Pick a moment where the screen shows something readable.
2. Get the take's files from `get_session`: `take-NN-camera.mov` and `take-NN-screen.mov`. The screen file runs on the same clock. Its `screen offset` (in `SESSION.md`) is how many seconds after the camera file it starts. So the screen time is the camera time minus the offset.
3. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/split-screen/`.
4. Find the screen size with `ffprobe -v error -show_entries stream=width,height take-NN-screen.mov`. Set `SCREEN.aspect`. Look at a frame of the screen and set `SCREEN.x`, `SCREEN.y` and `SCREEN.show` to the part to show. Change `CAM`, `LABELS` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size `W` x `H`.
5. Add three steps to the recipe. The first step cuts the camera. The second step cuts the screen at the same moment. The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take>-camera.mov",
              "-vf", "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>",
              "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "split-screen/footage.mp4"],
      "makes": ["split-screen/footage.mp4"]},
     {"run": ["ffmpeg", "-y", "-ss", "<screen time>", "-t", "<D>", "-i", "../../<take>-screen.mov",
              "-vf", "fps=<fps>,setsar=1",
              "-an", "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "split-screen/screen.mp4"],
      "makes": ["split-screen/screen.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "split-screen", "-q", "delivery", "-o", "split-screen.mp4"],
      "makes": ["split-screen.mp4"]}
   ]
   ```

   `<W>` and `<H>` are the edit's size. `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<screen time>` is `<take time>` minus the screen offset. `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in the camera `-vf`. For a b-roll clip instead of a screen recording, cut any part of it in the second step.
6. Add the layer: `"over": [{"file": "_edit/<name>/split-screen.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the effect. The face must sit well in its half, and you must be able to read the screen.

The screen offset in `SESSION.md` is rounded to whole seconds. Both files carry the mic, so you can find the exact offset by matching the two waveforms. If the screen action looks late or early against the voice, move `<screen time>` by up to 1 s.

## Limits

- Made for 9:16, 4:5, 1:1 and 16:9. Other sizes use the layout of the nearest shape.
- In 16:9 the speaker half is a crop of the shot: the face must be near `CAM.wide.x`.
- The screen half is about 1040x920 px in 9:16 (about 1040x600 in 4:5, 1040x480 in 1:1, 860x1040 in 16:9). Small UI text (sidebars, tabs) is hard to read even with cover. Show one column or one panel.
- The speaker half crops the shot. In a close-up the top of the head is cut. If the speaker moves a lot up or down, the face can move out of the half. Pick a calmer moment.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The layer has no sound. The edit's voice plays under it.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout. The idea (a speaker and a screen in a vertical split) is a common technique.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
