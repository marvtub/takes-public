# Rack focus

## What it does

The room behind the speaker slides out of focus and gets a little darker, with a soft dark edge round the frame. The speaker stays sharp. The shot pushes in slowly, as if a fast lens racked to the face. Then it racks back and the room is sharp again.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `LOOK.blur` | How soft the room gets. All sizes are px for a 1080 px short side. Other frames scale them. |
| `LOOK.dark` | How bright the room stays (1 = as filmed) |
| `LOOK.push` | The push in (1 = none) |
| `LOOK.at` | The point it pushes to, as parts of the frame (about the face) |
| `AT` | When the pull starts (`pull`) and how long it takes (`pullFor`), when it racks back (`back`) and how long that takes (`backFor`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.2 s now). The times in `AT` are seconds from its start |

The soft room is the clean plate blurred, not the footage, so there is no dark halo round the body.

## How to make it for a video

The composition has the footage, a blurred clean plate of the room, and the speaker cut out of the same footage in front. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.2 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/rack-focus/`.
3. Change `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Make `rack-focus/plate.png` once, before the render: the room without the speaker, at `<W>`x`<H>`, framed like the footage.
   - Best: a frame of the take where the speaker is out of shot. Cut it with the same `-vf` as the footage step: `ffmpeg -y -ss <time> -i ../../<take file> -frames:v 1 -vf "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>" rack-focus/plate.png`.
   - Else: save a frame of the moment the same way as `rack-focus/frame.png`. Call the Takes `make_image` tool with `images` = that frame, `format` = the edit's shape, and a prompt like "the same room, same camera and light, with the person removed; fill in what is behind them". Then scale the image it returns to the frame: `ffmpeg -y -i <made image> -vf "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>" rack-focus/plate.png`.
   - Look at the plate next to the frame. Walls, edges and furniture must sit in the same place, or the room jumps when the plate comes on.
5. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "rack-focus/footage.mp4"],
      "makes": ["rack-focus/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "rack-focus/footage.mp4", "-o",
              "rack-focus/person.webm", "--quality", "best"],
      "makes": ["rack-focus/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "rack-focus", "-q", "delivery", "-o",
              "rack-focus.mp4"],
      "makes": ["rack-focus.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
6. Add the layer: `"over": [{"file": "_edit/<name>/rack-focus.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at a frame when the room is fully soft. There must be no halo or second outline round the body.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- The plate must match the footage. If the camera moves during the window, the soft room does not line up.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
