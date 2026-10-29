# Colour grade

## What it does

A before/after wipe. The left side shows the footage flat, like log footage before a grade. The right side shows a cinematic grade. A white divider with a round handle sweeps across the frame. Small BEFORE and AFTER labels sit at the top. In every format the handle sits at mid height and the labels near the top corners. At the end the divider leaves to the left, so the last frames are fully graded.

The grade itself is reusable. It is an ffmpeg filter chain in `src/grade.sh`, and the same grade as a 3D LUT in `src/cinematic.cube`.

Use it only when the user asks for it.

## What to change

In `src/index.html`, at the top of the script:

| Value | What it controls |
|---|---|
| `TEXT` | The label text |
| `START` | Where the divider stands at the first frame (percent from the left: 100 = all before, 0 = all after) |
| `MOVES` | The sweeps: `[start time, seconds, to]` |
| `AT` | When the labels enter and when the divider leaves (seconds) |
| `data-duration` | The length, on `#root` and on both `<video>` tags (seconds) |
| `FRAME` | The frame size, read from `data-width` / `data-height` on `#root`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |

In `src/grade.sh`:

| Value | What it controls |
|---|---|
| `GRADE` | The cinematic grade: contrast, cool shadows, warm highlights, soft ends |
| `VIGNETTE` | A soft dark edge. It is not in the LUT |
| `FLAT` | The flat "before" look |
| `BEFORE=source` | Use the footage as it is for the before side, not the flat look |
| `[WxH]` (third argument) | The size of the two clips: the edit's frame size. Default 1080x1920 |

## How to make it for a video

The composition needs two clips of the moment: `before.mp4` and `after.mp4`. `grade.sh` makes both from one clip. The render is a full-frame layer.

1. Pick the cut time `T` where the wipe starts and its length `D` (6 s is typical). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/color-grade/`.
3. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D` on `#root` and on both `<video>` tags. Scale the times in `MOVES` and `AT` if `D` is not 6.
4. Add three steps to the recipe:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>",
              "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "color-grade/moment.mp4"],
      "makes": ["color-grade/moment.mp4"]},
     {"run": ["sh", "color-grade/grade.sh", "color-grade/moment.mp4", "color-grade", "<W>x<H>"],
      "makes": ["color-grade/before.mp4", "color-grade/after.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "color-grade", "-q", "delivery", "-o", "color-grade.mp4"],
      "makes": ["color-grade.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). If the recipe has `frame.crop`, add `-vf crop=w:h:x:y` to the first step. `grade.sh` scales and crops to `<W>x<H>` itself: the edit's frame size (1080x1920 when you leave it out).
5. Add the layer: `"over": [{"file": "_edit/<name>/color-grade.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame where the divider is in the middle.

After the layer ends, the edit shows the footage without the grade again. To keep the grade after the wipe, also add `color-grade/after.mp4` (made for a longer window) as a second full-frame layer, or grade the whole cut with the `GRADE` chain.

### Only the grade

To grade any clip without the wipe: `ffmpeg -i in.mp4 -vf "lut3d=file=cinematic.cube" out.mp4`, or copy the `GRADE` chain from `grade.sh`. The LUT also loads in DaVinci Resolve and Final Cut Pro.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9. The layout follows `data-width` / `data-height`; sizes are made for a 1080 px short side.
- The grade suits normal, well-lit footage. It is a look, not a correction: it does not fix white balance or exposure. Very dark or very orange footage can look too heavy. Check a frame first.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit.
- `cinematic.cube` is a 36-point LUT. It matches the `GRADE` chain within about 45 dB PSNR (no visible difference).
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. The grade, the flat look and `cinematic.cube` are our own, made from ffmpeg filters. `cinematic.cube` is CC0: free to use, change and share. No third-party LUT is used.
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
