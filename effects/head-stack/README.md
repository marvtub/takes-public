# Head stack

## What it does

The shot punches in a little. Small cream name tags drop from above the frame, one after another, with a speed blur. They stack up on the speaker's head like a pile of labels, each a little crooked. A few land on the shoulder instead. The pile rides on the head as the head moves. Then a gust sweeps them all off, up and away: the head tags to one side, the shoulder tags to the other.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `TAGS` | The tags in the order they drop: `[big word, small word, where it lands]`. The small word can be `""`. Where: `"head"` or `"shoulder"` |
| `LOOK.cream` | The tag colour |
| `LOOK.shoulder` | Where the shoulder pile sits (`x`, `y` as parts of the frame) and its tilt in degrees |
| `LOOK.punch`, `LOOK.blur` | The punch-in on the head (1 = none) and the speed blur as a tag falls |
| `AT` | When the first tag drops (`first`), the time between drops (`every`) and the gust (`gust`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.6 s now). The times in `AT` are seconds from its start |

`track.py` takes its values on the command line: `python3 track.py <folder> [seconds]`:

| Value | What it controls |
|---|---|
| `seconds` | How much of `person.webm` it reads. Use `D` |

Each head tag sits one tag height (66 px at 1080) above the last. With little room above the head, put fewer tags on the head and more on the shoulder.

Keep `AT.gust` at least 0.4 s after the last drop: `AT.first + (tags - 1) * AT.every`.

The layout follows the frame:

- The pile follows the top of the head, read from the matte frame by frame, in every shape. Set `LOOK.shoulder` again for each shape.

Layout by frame shape: When there is no room above the head for the pile (a square or wide shot cut close at the top), the head pile sits beside the head, on its right, and still moves with it.

## How to make it for a video

The composition has the footage and the tags on top. `track.py` follows the top of the head in the speaker's matte, frame by frame, and writes `track.js`, so the pile moves with the head. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.6 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/head-stack/`.
3. Change `TAGS`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add four steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step tracks the top of the head. The fourth step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "head-stack/footage.mp4"],
      "makes": ["head-stack/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "head-stack/footage.mp4", "-o",
              "head-stack/person.webm", "--quality", "best"],
      "makes": ["head-stack/person.webm"]},
     {"run": ["python3", "head-stack/track.py", "head-stack", "<D>"],
      "makes": ["head-stack/track.js"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "head-stack", "-q", "delivery", "-o",
              "head-stack.mp4"],
      "makes": ["head-stack.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/head-stack.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame before the gust. The pile must sit on the head and move with it, and the top tag must stay inside the frame.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- The track reads the highest point of the matte. A raised hand above the head moves the pile to the hand.
- `track.py` needs Python 3 with numpy.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Font: IBM Plex Mono, SIL Open Font License 1.1 (`src/fonts/OFL-IBMPlexMono.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
