# Impact frame

## What it does

The shot snaps to a manga impact frame. The speaker is a two-tone ink drawing: cream with black contour lines on the eyes, nose, mouth and clothes, and solid ink only in the darkest parts. Radial speed lines burst out behind the head. A huge word sits across the chest, over a black band with cream lines rushing down. The lines are redrawn every 2 frames, so they flicker like hand-drawn frames. On each hit the whole frame flips to negative for a moment. The frame shakes a little at the start. Then it cuts back.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `WORD.text` | The word across the chest |
| `WORD.y` | Where the middle of the word sits, as a part of the frame height. The black band starts just above it |
| `WORD.size` | The word size. All sizes are px for a 1080 px short side. Other frames scale them. A long word shrinks to fit the width |
| `LOOK.cream`, `LOOK.ink` | The paper and ink colours |
| `LOOK.lines` | How many speed lines |
| `LOOK.shake` | How hard it shakes at the start (px at 1080) |
| `AT` | The cut in (`in`), the cut out (`out`), the hits that flip to negative (`hits`, a list of times) and how long each flip lasts (`flip`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (2.4 s now). The times in `AT` are seconds from its start |

In `src/ink.py`, at the top, and on its command line (`python3 ink.py <folder> [seconds] [still-at]`):

| Value | What it controls |
|---|---|
| `LINE` | Contour strength: lower = more lines |
| `SIGMA` | Contour width (px at 1080) |
| `DARK` | Below this brightness (0 to 1) it is solid ink |
| `seconds` | How much of `person.webm` it reads. Use `D` |
| `still-at` | A time in seconds: it writes only `ink-test.png` from that moment, to check the look before the full run |

The speed lines burst from a point in the middle of the frame, at 28 % of its height. Use a shot where the head is near there.

The layout follows the frame:

- The burst, the band and the word span the whole frame in every shape. In 16:9 the word fits the width and the speed lines fill the sides.

## How to make it for a video

The composition has the footage and, on top, the ink frame: the speed lines, the speaker as an ink drawing, the black band and the word. `ink.py` turns the speaker's cutout into the ink drawing (contour lines from a difference of blurs, side light evened first) and writes `person-ink.webm`. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (2.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/impact-frame/`.
3. Change `WORD`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add four steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step draws the speaker in ink. The fourth step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=30", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "impact-frame/footage.mp4"],
      "makes": ["impact-frame/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "impact-frame/footage.mp4", "-o",
              "impact-frame/person.webm", "--quality", "best"],
      "makes": ["impact-frame/person.webm"]},
     {"run": ["python3", "impact-frame/ink.py", "impact-frame", "<D>"],
      "makes": ["impact-frame/person-ink.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "impact-frame", "-q", "delivery", "-o",
              "impact-frame.mp4"],
      "makes": ["impact-frame.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). The footage step uses `fps=30` here: `ink.py` writes `person-ink.webm` at 30 fps, so the matte must be 30 fps too. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.

   To check the drawing first, run `python3 impact-frame/ink.py impact-frame <D> 1.0` once. It writes `impact-frame/ink-test.png` from 1 s in. Change `LINE`, `SIGMA` and `DARK` until the face reads.
5. Add the layer: `"over": [{"file": "_edit/<name>/impact-frame.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame between the hits. The face must read as a drawing, and the word must read on the band.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- `ink.py` needs Python 3 with numpy and OpenCV (`cv2`).
- The negative flips are hard flashes. Keep them to 2 or 3.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Contours: an XDoG filter (difference of Gaussians), our own code with OpenCV (Apache-2.0).
- Font: Inter, SIL Open Font License 1.1 (`src/fonts/OFL-Inter.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
