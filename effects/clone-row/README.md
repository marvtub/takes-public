# Clone row

## What it does

The shot punches in a little on the head. Then copies of the speaker shoot out from behind them, to the left and the right. Each copy is smaller and darker the further out it sits, so the row seems to go back into the room. All copies talk in sync, because they are the same cutout. The room gets a little darker while they are out. Then the copies snap back behind the speaker with a blur smear, and the shot is normal again.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `HEAD` | The middle of the speaker's head, as parts of the frame (0 to 1). The copies line up on it |
| `ROW.count` | How many copies on each side, 1 to 4 |
| `ROW.out` | How far out each copy sits, from the head, as a part of the frame width. One value per place, near to far |
| `ROW.size` | The size of each copy (1 = the speaker's size) |
| `ROW.light` | How bright each copy is (1 = as filmed) |
| `ROW.drop` | How far each copy sits lower than the one before it, as a part of the height |
| `LOOK.punch` | The punch-in on the shot (1 = none) |
| `LOOK.room` | How bright the room stays while the copies are out (1 = as filmed) |
| `LOOK.blur` | The blur as the copies shoot out and back. All sizes are px for a 1080 px short side. Other frames scale them. |
| `AT` | When the shot punches in (`punch`), the first copy comes out (`out`), the time between copies (`stagger`) and when they go back (`back`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.6 s now). The times in `AT` are seconds from its start |

The layout follows the frame:

- Tall and square (9:16, 4:5, 1:1): the row spreads by the frame width. The outer copies reach the edges and go past them.
- Wide (wider than 1.2:1, so 16:9): the row spreads by 0.9 times the frame height, so the copies stay near the speaker and the sides of the frame stay clear.

## How to make it for a video

The composition has the footage and nine copies of the speaker's cutout: eight clones and the speaker in front. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.6 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/clone-row/`.
3. Change `HEAD`, `ROW`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "clone-row/footage.mp4"],
      "makes": ["clone-row/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "clone-row/footage.mp4", "-o",
              "clone-row/person.webm", "--quality", "best"],
      "makes": ["clone-row/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "clone-row", "-q", "delivery", "-o",
              "clone-row.mp4"],
      "makes": ["clone-row.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/clone-row.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame when all copies are out. Their heads must line up on the row, and the speaker must stay in front.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9 (see the layout above).
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- In a bright room the copies read busier. Lower `LOOK.room` to darken the room more while they are out.
- The copies are scaled from the head, so their bodies end low in the frame. Keep the speaker's body in shot to the bottom edge.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
