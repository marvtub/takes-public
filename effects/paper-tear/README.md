# Paper tear

## What it does

A full-frame page rips in two down a jagged line through the middle. Both halves get a white torn fibre edge, with slightly different teeth so the edges do not match exactly, like real paper. The paper gives a little, then the halves twist and fall away to the sides. The shot is under them.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `TEAR.top`, `TEAR.bottom` | Where the tear runs, as a part of the width at the top and at the bottom |
| `TEAR.jag` | How jagged the tear is. All sizes are px for a 1080 px short side. Other frames scale them. |
| `TEAR.fibre` | How wide the white fibre edge is (px at 1080) |
| `TEAR.seed` | Changes the shape of the tear. The same seed gives the same tear in every render |
| `LOOK.fibre` | The colour of the fibre edge |
| `AT` | When the rip starts (`rip`) and how long until the halves are gone (`for`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (1.8 s now). The times in `AT` are seconds from its start |

Until `AT.rip` the layer shows only the page, so it can take over from the page layer with no jump.

## How to make it for a video

The composition has the footage and two copies of the page still, each clipped to one side of the tear. It needs no cutout. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (1.8 s now; keep the times in `AT` inside it). Start it at the moment the page is last fully on screen. The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/paper-tear/`.
3. Change `TEAR`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Make `paper-tear/cover.png` once: a still of the page at that moment, at `<W>`x`<H>`. After a Press front layer that starts at `T0`, take the frame at `T - T0` from its render: `ffmpeg -y -ss <T - T0> -i press-front.mp4 -frames:v 1 paper-tear/cover.png`. Pick `T` before the page's `AT.out`, while the page still shows.
5. Add two steps to the recipe. The first step cuts the footage of the moment. The second step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "paper-tear/footage.mp4"],
      "makes": ["paper-tear/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "paper-tear", "-q", "delivery", "-o",
              "paper-tear.mp4"],
      "makes": ["paper-tear.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.

   Put the paper tear layer after the page layer in `over`, so it sits on top.
6. Add the layer: `"over": [{"file": "_edit/<name>/paper-tear.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at the first frame of the layer and the frame before it. The page must not jump. Then look at a frame in the middle of the rip.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- The page is a still, so it stops moving for `AT.rip` seconds. Keep `AT.rip` short (0.3 s).
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
