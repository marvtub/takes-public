# Code body

## What it does

A thin green line wipes down from the top. Behind it the shot turns into code. The speaker is made of monospace letters, coloured by the footage and a little brighter. Bright parts become solid blocks with a dark letter in them. The room round the speaker is faint green code. The letters start big and blocky and get finer in four steps, so the face resolves out of the code. The text creeps each frame, like a live terminal. Then a wipe going up brings the shot back.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `LOOK.bg` | The colour behind the code |
| `LOOK.room`, `LOOK.roomAlpha` | The colour of the room's code and how strong it is (0 to 1) |
| `LOOK.lift` | How much brighter the speaker's letters are than the footage |
| `LOOK.block` | How bright a cell must be (0 to 255) to become a solid block |
| `LOOK.steps`, `LOOK.hold` | The cell sizes the face resolves through (1 = the finest grid in `grid.js`), each shown for `hold` seconds |
| `SOURCE` | A little further down in the script: the text the letters come from. Any code or words work. It is read left to right, row by row |
| `AT` | When the wipe down starts (`in`), how long a wipe takes (`wipe`), when the wipe up starts (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.4 s now). The times in `AT` are seconds from its start |

`grid.py` takes its values on the command line: `python3 grid.py <folder> [cols] [fps] [seconds]`:

| Value | What it controls |
|---|---|
| `cols` | How many letters across at the finest step (72 now). More columns = finer letters and a bigger `grid.js` |
| `fps` | How many grid frames a second (15) |
| `seconds` | How much of the footage it reads. Use `D` |

The speaker gets auto levels: the brightest tenth of their cells maps to near white. So dark skin and back light still read.

The layout follows the frame:

- The grid has `cols` letters across, and as many rows as the frame shape needs. The cells stay about square in every shape.

## How to make it for a video

The composition has the footage and a canvas of letters. `grid.py` samples the footage and the speaker's matte into a grid of cells, 15 times a second, and writes `grid.js`. The page draws the letters from it. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/code-body/`.
3. Change `LOOK`, `SOURCE` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add four steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step makes `grid.js` from both. The fourth step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "code-body/footage.mp4"],
      "makes": ["code-body/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "code-body/footage.mp4", "-o",
              "code-body/person.webm", "--quality", "best"],
      "makes": ["code-body/person.webm"]},
     {"run": ["python3", "code-body/grid.py", "code-body", "72", "15", "<D>"],
      "makes": ["code-body/grid.js"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "code-body", "-q", "delivery", "-o",
              "code-body.mp4"],
      "makes": ["code-body.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/code-body.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame after the last step. The face must read in the letters, and the room must stay faint.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- `grid.py` needs Python 3 with numpy. `grid.js` is about 2.5 MB for 3.4 s at 72 columns in 9:16.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Font: IBM Plex Mono, SIL Open Font License 1.1 (`src/fonts/OFL-IBMPlexMono.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
