# Press front

## What it does

A hard cut to the front page of a newspaper. It has a masthead with two ears, a date line, a big headline and an italic deck, and columns of small text. In the middle the speaker is a live halftone photo: round ink dots on a 45° screen, still talking, with a caption. A pull quote, a contents list and a small box sit under it. The page creeps in slowly, like a camera over a print. Then it cuts back. To tear the page away instead, use the Paper tear effect after it.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `PAGE.masthead`, `PAGE.ears` | The paper's name, and the two small boxes beside it |
| `PAGE.dateline` | The three parts of the date line |
| `PAGE.headline`, `PAGE.deck` | The big headline and the italic line under it. Both shrink to fit the width |
| `PAGE.caption` | The caption under the photo |
| `PAGE.left`, `PAGE.right`, `PAGE.box` | The columns: `[heading, byline or "", text]`. The text can use `<i>` for italic. Text that does not fit is cut off |
| `PAGE.quote` | The pull quote under the photo |
| `PAGE.toc` | The contents list: `[name, time]` |
| `PORTRAIT` | The part of the footage that becomes the photo: centre `x`, centre `y`, `w`, `h`, as parts of the frame. `halftone.py` reads this line: keep it on one line, and run `halftone.py` again after a change |
| `LOOK.paper`, `LOOK.ink` | The paper and ink colours |
| `LOOK.dot` | The dot size (1 = normal) |
| `LOOK.creep` | How far the page creeps in (1 = not at all) |
| `AT` | The cut to the page (`in`) and the cut back (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3 s now). The times in `AT` are seconds from its start |

In `src/halftone.py`, at the top, and on its command line (`python3 halftone.py <folder> [seconds] [lines] [cols] [fps]`):

| Value | What it controls |
|---|---|
| `ROOM` | How dark the room behind the speaker prints (0 = ink, 1 = paper) |
| `CONTRAST` | How much contrast the photo gets |
| `seconds` | How much of the footage it reads. Use `D` |
| `lines`, `cols` | The dot grid: rows and columns (110 and 72) |
| `fps` | Photo frames a second (15) |

Write all of `PAGE` for the video. The copy in the file is only an example. The words are small, so keep them true and short.

The layout follows the frame:

- 9:16: the sheet fills the frame.
- 4:5, 1:1 and 16:9: the sheet keeps its 9:16 shape, as big as fits, and stands in the middle on a dark ground.

## How to make it for a video

The composition has the footage and the page on top. `halftone.py` samples the photo from the footage and the speaker's matte, 15 times a second, and writes `lum.js`. The page draws the dot screen from it every frame. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/press-front/`.
3. Change `PAGE`, `PORTRAIT`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add four steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step makes the halftone data. The fourth step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "press-front/footage.mp4"],
      "makes": ["press-front/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "press-front/footage.mp4", "-o",
              "press-front/person.webm", "--quality", "best"],
      "makes": ["press-front/person.webm"]},
     {"run": ["python3", "press-front/halftone.py", "press-front", "<D>", "110", "72"],
      "makes": ["press-front/lum.js"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "press-front", "-q", "delivery", "-o",
              "press-front.mp4"],
      "makes": ["press-front.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/press-front.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame in the middle. The face must read in the dots, and the headline and deck must fit on one line each.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Made for 9:16. In other shapes the page stands in the middle (see the layout above).
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- `halftone.py` needs Python 3 with numpy and OpenCV (`cv2`).
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: EB Garamond and Old Standard TT, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
