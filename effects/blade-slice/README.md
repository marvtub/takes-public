# Blade slice

## What it does

A thin white flash shoots across the frame on a slant in three frames. The shot splits along it. The top half slides one way along the cut and the bottom half the other way, with a dark gap between them, as if the picture were cut with a blade. A small zoom keeps the frame edges filled. A moment later the halves slide back together and the seam is gone.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `CUT.y` | Where the cut crosses the middle of the frame, as a part of the height. About the mouth reads best |
| `CUT.angle` | The slant, in degrees. Negative = it rises to the right |
| `CUT.slide` | How far each half moves along the cut. All sizes are px for a 1080 px short side. Other frames scale them. |
| `CUT.gap` | How far the halves move apart across the cut (px at 1080) |
| `LOOK.flash` | The thickness of the flash line (px at 1080) |
| `AT` | When the slash comes (`slash`), the halves part (`part`, `partFor`) and close (`close`, `closeFor`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (2.8 s now). The times in `AT` are seconds from its start |

The layout follows the frame:

- The cut goes from edge to edge through the middle of the frame at `CUT.y`, in every shape.

## How to make it for a video

The composition has two copies of the footage, each clipped to one side of the cut line. It needs no cutout. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (2.8 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/blade-slice/`.
3. Change `CUT`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add two steps to the recipe. The first step cuts the footage of the moment. The second step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "blade-slice/footage.mp4"],
      "makes": ["blade-slice/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "blade-slice", "-q", "delivery", "-o",
              "blade-slice.mp4"],
      "makes": ["blade-slice.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/blade-slice.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame when the halves are apart. The cut must cross near the mouth, and no black may show at the frame edges.

A short swish sound on the slash helps. Add it with the recipe's `sfx` at `T + AT.slash`.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
