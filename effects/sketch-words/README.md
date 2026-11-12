# Sketch words

## What it does

The room cuts to warm paper with pencil guide lines. A small word writes itself by hand. Then a big serif word is sketched: each letter's outline is drawn on in pencil, in two loose passes. Red hatching scribbles in from left to right and fills the letters. A pencil underline swipes under the word. Everything boils a little, like stop motion. The speaker stays in front with a soft shadow on the paper. Then it cuts back to the room.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `WORDS.small` | The small handwritten word above the big one |
| `WORDS.big` | The big sketched word |
| `PLACE.baseline` | Where the big word's baseline sits, as a part of the frame height. The head should cover a little of the bottom of the word, or sit just under it |
| `PLACE.size` | The big word's size. All sizes are px for a 1080 px short side. Other frames scale them. A long word shrinks to fit |
| `PLACE.left` | The space kept at each side, as a part of the width |
| `LOOK.pencil`, `LOOK.guide`, `LOOK.under` | The colours of the outline, the guide lines and the underline |
| `LOOK.boil` | How many frames each wobble holds (2 = a new wobble every 2 frames) |
| `AT` | When it cuts to paper (`cut`), the small word writes (`small`, `smallFor`), the outlines start (`big`, `every` between letters, `draw` per letter), the hatching runs (`fill`, `fillFor`), the underline (`under`), the cut back (`back`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.4 s now). The times in `AT` are seconds from its start |

The red hatching colours are in the `<pattern id="hatch">` and `<pattern id="hatch2">` tags in the page.

The layout follows the frame:

- The word size comes from the short side and shrinks to the frame width. In 16:9 there is room beside the head; keep `PLACE.baseline` above the head.

Layout by frame shape: Wide frames (16:9) put the word beside the head, on the left, and make it fit a third of the width. Square frames keep it centred and move it down so the small word stays in the frame. Tall frames use `PLACE` as set.

## How to make it for a video

The composition has the footage, one SVG for the paper and the drawing, and the speaker cut out of the same footage in front. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/sketch-words/`.
3. Change `WORDS`, `PLACE`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "sketch-words/footage.mp4"],
      "makes": ["sketch-words/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "sketch-words/footage.mp4", "-o",
              "sketch-words/person.webm", "--quality", "best"],
      "makes": ["sketch-words/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "sketch-words", "-q", "delivery", "-o",
              "sketch-words.mp4"],
      "makes": ["sketch-words.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/sketch-words.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame after the underline. The big word must read, and the head must cover at most the bottom of it.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- With little room above the head the word sits high. Use a short word, or set a smaller `PLACE.size`.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: Caveat and EB Garamond, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
