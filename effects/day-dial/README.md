# Day dial

## What it does

A thin gold clock hand sweeps once round the speaker's head. Behind it the room turns to warm paper. A clock face draws on as the hand passes: a ring, a thin inner ring, the hour numbers in a serif, and a word in every hour in italic. A second word rides on the hand. At the end the hand stands as a thin gold line at 12. The speaker stays in front and casts a soft shadow on the paper. Then the hand sweeps back, and the room returns.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `HEAD` | The middle of the dial: the speaker's head, as parts of the frame (0 to 1) |
| `WORDS.hour` | The word set in every hour (12 shows only the number) |
| `WORDS.hand` | The word that rides on the hand |
| `LOOK.radius` | The size of the ring, as a part of the frame's short side |
| `LOOK.paper`, `LOOK.ink`, `LOOK.hand` | The paper colour, the colour of the face and the type, the colour of the hand |
| `LOOK.shadow` | The size of the speaker's shadow on the paper. All sizes are px for a 1080 px short side. Other frames scale them. |
| `AT` | When the sweep starts (`sweep`) and how long it takes (`sweepFor`), when the hand sweeps back (`back`) and how long that takes (`backFor`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.4 s now). The times in `AT` are seconds from its start |

Use short words: the hour words sit between the two rings. A word of 3 to 5 letters reads best.

The layout follows the frame:

- The dial is drawn round `HEAD` and sized from the short side, so it has the same size in every shape. The paper covers the whole frame.

Layout by frame shape: The ring stays inside the frame: when the head sits high (most square and wide shots), the ring gets smaller than `LOOK.radius`. Set `HEAD` to the middle of the head in the shot.

## How to make it for a video

The composition has the footage, the paper with the dial, and the speaker cut out of the same footage in front. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/day-dial/`.
3. Change `HEAD`, `WORDS`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "day-dial/footage.mp4"],
      "makes": ["day-dial/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "day-dial/footage.mp4", "-o",
              "day-dial/person.webm", "--quality", "best"],
      "makes": ["day-dial/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "day-dial", "-q", "delivery", "-o",
              "day-dial.mp4"],
      "makes": ["day-dial.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/day-dial.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame after the sweep. The dial must be round the head, the numbers must not leave the frame, and the head must be in front of the ring.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- The paper goes to the bottom of the frame. The speaker's body is in front of it.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Font: EB Garamond, SIL Open Font License 1.1 (`src/fonts/OFL-EBGaramond.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
