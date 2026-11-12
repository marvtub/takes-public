# Letter dive

## What it does

The shot drops away into the bottom corner and warm paper shows. A word types on in a big serif, letter by letter, each letter rising into place. The letters are holes in the paper: the footage plays inside them. Then the camera dives into one letter. The word grows, slowly at first, then fast, until that letter fills the frame. The paper is gone and you are back in the shot.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `WORD.text` | The word |
| `WORD.dive` | Which letter the camera dives into: its place in the word, from 0 |
| `WORD.into` | Where in that letter: 0 = its left edge, 1 = its right edge. 0.5 hits the stem of an i or an l |
| `WORD.y` | Where the word sits, as a part of the frame height |
| `LOOK.paper` | The paper colour |
| `LOOK.size` | The word size. All sizes are px for a 1080 px short side. Other frames scale them. A long word shrinks to fit 93 % of the width |
| `LOOK.track` | The letter spacing, as a part of the size |
| `AT` | When the shot drops away (`drop`), the first letter (`type`), the time per letter (`every`), how long a letter takes to rise (`rise`), when the dive starts (`dive`) and how long it takes (`diveFor`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3 s now). The times in `AT` are seconds from its start |

The dive point must be inside the letter's stroke, where the footage shows. Pick a letter with a thick straight stem: i, l, d, h, b. Do not dive into the dot of an i.

The layout follows the frame:

- The word is measured once the font loads, so it always fits the width and the dive hits the chosen letter. In 16:9 the word is as big as the short side allows.

## How to make it for a video

The composition has the footage and a sheet of paper with the word cut out of it (an SVG mask), so the live shot shows through the letters. It needs no cutout. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/letter-dive/`.
3. Change `WORD`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add two steps to the recipe. The first step cuts the footage of the moment. The second step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "letter-dive/footage.mp4"],
      "makes": ["letter-dive/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "letter-dive", "-q", "delivery", "-o",
              "letter-dive.mp4"],
      "makes": ["letter-dive.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/letter-dive.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame when the whole word is on, and at the frames of the dive. The footage must show inside the letters, and the dive must end in the shot, not on paper.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Font: Old Standard TT, SIL Open Font License 1.1 (`src/fonts/OFL-OldStandard.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
