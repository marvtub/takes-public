# Live cursor

## What it does

A cursor with a name tag flies in from the side. It presses, and drags a gold box over the speaker's head and chest. When it lets go, the box becomes a selection: a gold frame, eight square handles, a badge with the box size, and a thin light outline round the body. Then the cursor drags the speaker sideways, like a layer in a design tool. The room behind stays in place. A pink guide line flashes when the body passes the middle of the frame. The cursor lets go, the speaker slides back, and the cursor leaves.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `SEL` | The box the cursor selects: `x`, `y` (top left), `w`, `h`, as parts of the frame (0 to 1). Put it round the head and chest |
| `CURSOR.name` | The name on the cursor's tag |
| `CURSOR.from` | Where the cursor flies in from, as parts of the frame. Values over 1 start outside the frame |
| `CURSOR.drag` | How far the cursor drags the speaker, as a part of the frame width. Negative = to the left |
| `CURSOR.lift` | A small move up (negative) or down while the speaker is dragged, as a part of the height |
| `LOOK.gold`, `LOOK.outline` | The colour of the box, handles and badge, and the colour of the outline round the body |
| `LOOK.line`, `LOOK.handle`, `LOOK.badge`, `LOOK.tag`, `LOOK.arrow` | Line width, handle size, badge text size, tag text size and arrow height. All sizes are px for a 1080 px short side. Other frames scale them. |
| `AT` | When the cursor flies in (`start`), presses (`press`), ends the box (`marquee`), starts the drag (`drag`), lets go (`release`) and is gone (`gone`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (4 s now). The times in `AT` are seconds from its start |

The badge shows the real box size in px at a 1080 px short side, and the numbers move a little during the drag, like a live resize.

`SEL` is in parts of the frame. Set it again for each frame shape: in 16:9 the speaker fills a smaller part of the width.

## How to make it for a video

The composition has three layers: the footage, a clean plate of the room, and the speaker cut out of the same footage. While the speaker is dragged, the plate fills the place where they were. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/live-cursor/`.
3. Change `SEL`, `CURSOR`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Make `live-cursor/plate.png` once, before the render: the room without the speaker, at `<W>`x`<H>`, framed like the footage.
   - Best: a frame of the take where the speaker is out of shot. Cut it with the same `-vf` as the footage step: `ffmpeg -y -ss <time> -i ../../<take file> -frames:v 1 -vf "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>" live-cursor/plate.png`.
   - Else: save a frame of the moment the same way as `live-cursor/frame.png`. Call the Takes `make_image` tool with `images` = that frame, `format` = the edit's shape, and a prompt like "the same room, same camera and light, with the person removed; fill in what is behind them". Then scale the image it returns to the frame: `ffmpeg -y -i <made image> -vf "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>" live-cursor/plate.png`.
   - Look at the plate next to the frame. Walls, edges and furniture must sit in the same place, or the room jumps when the plate comes on.
5. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "live-cursor/footage.mp4"],
      "makes": ["live-cursor/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "live-cursor/footage.mp4", "-o",
              "live-cursor/person.webm", "--quality", "best"],
      "makes": ["live-cursor/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "live-cursor", "-q", "delivery", "-o",
              "live-cursor.mp4"],
      "makes": ["live-cursor.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
6. Add the layer: `"over": [{"file": "_edit/<name>/live-cursor.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at a frame in the middle of the drag. The room must show no copy of the speaker at the old place, and the box must sit round the head and chest.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9. Sizes follow the short side; `SEL` and `CURSOR` are parts of the frame.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- The plate must match the footage. If the camera moves during the window, the room jumps when the plate comes on.
- With a big `CURSOR.drag`, the edge of the matte can show at the bottom of the frame. Keep the drag under about 0.12.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: IBM Plex Mono and Inter, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
