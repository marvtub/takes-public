# Freeze sticker

## What it does

The picture freezes. The speaker lifts off the frame like a sticker, with a thick white outline and a soft shadow. The frozen background blurs and gets darker. A name tag pops on: the name in a warm accent box, and one short line under it. The voice keeps playing. Then the tag goes, the sticker settles flat, and the live footage goes on.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `TEXT.name`, `TEXT.role` | The name tag. Keep the name short (one or two words) and the role to 3 words or fewer |
| `LOOK.outline` | The white edge in px |
| `LOOK.lift`, `LOOK.tilt` | The sticker size while it is lifted (`1` = same size) and its turn in degrees |
| `LOOK.blur`, `LOOK.dim` | What happens to the frozen background |
| `LOOK.tag` | Where the name tag sits, by the shape of the frame: `tall` (9:16, 4:5), `square` (1:1) and `wide` (16:9). `x` is px from the left (keep it at 60 or more), `y` is from the top as a part of the frame height |
| `AT` | When the freeze starts, when the tag pops on, when it settles back (seconds of `footage.mp4`). The live footage returns 0.5 s after `AT.back` |
| `--accent` in `:root` | The colour of the name box |
| `FRAME` | The frame size, read from `data-width` / `data-height` on `#root`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |

The layout follows the frame. Tall and square: the tag sits low on the left, over the chest. Wide (16:9): the tag sits beside the head, left of it, at shoulder height.

The video is as long as `footage.mp4`. The freeze holds from `AT.freeze` to `AT.back` + 0.5 s. Keep 1 s or more of live footage after it.

## How to make it for a video

The composition has the live footage, one frozen frame (`still.png`), and the speaker cut out of that frame (`sticker.png`). The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (5 to 6 s is typical). The window must be inside one entry of the recipe's `cut`. Pick a freeze frame where the speaker is sharp, the eyes are open and the hands do not blur.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/freeze-sticker/`.
3. Set `data-width` and `data-height` on `#root` to the edit's size. Change `TEXT`, `LOOK` and `AT`.
4. Add four steps to the recipe. They cut the footage of the moment, take the frame at `AT.freeze`, cut the speaker out of that frame, and render the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>",
              "-vf", "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>",
              "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "freeze-sticker/footage.mp4"],
      "makes": ["freeze-sticker/footage.mp4"]},
     {"run": ["ffmpeg", "-y", "-ss", "<AT.freeze>", "-i", "freeze-sticker/footage.mp4", "-frames:v", "1",
              "freeze-sticker/still.png"],
      "makes": ["freeze-sticker/still.png"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "freeze-sticker/still.png",
              "-o", "freeze-sticker/sticker.png"],
      "makes": ["freeze-sticker/sticker.png"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "freeze-sticker", "-q", "delivery", "-o", "freeze-sticker.mp4"],
      "makes": ["freeze-sticker.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. `<AT.freeze>` must be the same number as `AT.freeze` in the script, or the picture jumps when it freezes. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/freeze-sticker.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the freeze. The outline must follow the speaker with no gaps, and the tag must be easy to read.

The matte of one frame takes less than 1 s. The steps run on every render.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9. The layout follows `data-width` / `data-height`; sizes are made for a 1080 px short side.
- It needs a head-and-shoulders shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds. The outline then goes around the person only. It can also take in furniture right next to the person (a sofa beside the shoulder), which then gets the white outline too. Pick a frame with clear space around the person, or clear the alpha of that area in `sticker.png`.
- The voice goes on during the freeze, so the lips do not move for about 3 s. Freeze on a pause or a short phrase, not on a key sentence.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout. The idea (a freeze-frame sticker with a name tag) is a common technique.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: Montserrat and Inter, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
