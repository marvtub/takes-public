# Orbit ring

## What it does

A ring of tall serif capitals whips in from the side with a blur and settles round the speaker's head. It turns like a planet's ring. The front half passes in front of the chin in warm gold. The back half goes behind the head, smaller and silver. The letters sit on the ring like on a turning drum: side letters squeeze thin, and back letters read mirrored. The shot punches in a little meanwhile. At the end the ring speeds up, drops to the neck and flattens. The front half fades first, so the last of the blurred band goes round behind the neck. Then it is gone.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `RING.text` | The text that goes round. It repeats `RING.repeat` times to fill the ring |
| `RING.center` | The middle of the ring, about the nose, as parts of the frame (0 to 1) |
| `RING.radius` | The ring's radius, as a part of the frame's short side |
| `RING.tilt` | How flat the ring looks: 0 = edge on, 1 = seen from above |
| `RING.turns` | Turns per second. Negative = the front moves right to left |
| `LOOK.size` | The letter height at the front. All sizes are px for a 1080 px short side. Other frames scale them. |
| `LOOK.front`, `LOOK.back` | The colour of the letters at the front and at the back |
| `LOOK.punch` | The punch-in on the shot (1 = none) |
| `LOOK.blur`, `LOOK.smear` | The blur, and the sideways motion blur when the ring spins fast (px at 1080) |
| `AT` | When the ring whips in (`in`) and how long that takes (`whip`), when it spins out (`out`) and how long that takes (`spinOut`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.4 s now). The times in `AT` are seconds from its start |

Keep `AT.out + AT.spinOut + 0.25` at or under `D`. Change `RING.repeat` or `LOOK.size` so the letters do not touch.

The layout follows the frame:

- The ring is sized from the short side, so it has the same size in every shape.

## How to make it for a video

Every letter is drawn twice: once behind the speaker's cutout and once in front. Only the copy on the right side of the head shows, so the head hides the back half. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/orbit-ring/`.
3. Change `RING`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "orbit-ring/footage.mp4"],
      "makes": ["orbit-ring/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "orbit-ring/footage.mp4", "-o",
              "orbit-ring/person.webm", "--quality", "best"],
      "makes": ["orbit-ring/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "orbit-ring", "-q", "delivery", "-o",
              "orbit-ring.mp4"],
      "makes": ["orbit-ring.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/orbit-ring.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the spin. The back letters must go behind the head and the front letters in front of the chin.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- If the speaker moves the head a lot, set `RING.center` to the middle of the head's path.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Font: Cinzel, SIL Open Font License 1.1 (`src/fonts/OFL-Cinzel.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
