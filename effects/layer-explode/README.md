# Layer explode

## What it does

The shot shrinks into a card and turns in 3D on a dark ground. The first title line types on. Then the card comes apart into the layers it is made of, like glass panes in a row: the room, the title, the speaker and the sound. Each pane gets a thin frame and a small label. The second title line types on. A waveform of the speaker's voice sits on the sound pane, and a play head moves along it. The panes drift a little. Then they slide back together, and the card fills the frame again.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `TITLE.lines` | The two title lines. The first types on as the card turns, the second when it comes apart |
| `TITLE.x`, `TITLE.y`, `TITLE.size` | Where the title sits (parts of the frame) and its size (px at 1080) |
| `LAYERS` | The pane labels, back to front: room, title, speaker, sound |
| `LOOK.ground` | The colour of the ground behind the card |
| `LOOK.card` | How small the card gets (1 = full frame) |
| `LOOK.turn`, `LOOK.tilt` | The 3D angles, in degrees |
| `LOOK.gap` | The space between panes. All sizes are px for a 1080 px short side. Other frames scale them. |
| `LOOK.played`, `LOOK.left` | The waveform colours: the played part and the rest |
| `LOOK.persp` | The 3D depth. Lower = stronger perspective |
| `AT` | When the card shrinks and turns (`turn`), comes apart (`explode`), starts to close (`close`) and fills the frame (`full`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.6 s now). The times in `AT` are seconds from its start |

`wave.py` takes its values on the command line: `python3 wave.py <audio or video> <start> <length> <out> [bars]`:

| Value | What it controls |
|---|---|
| `<audio or video>` | The take file. Its sound gives the waveform |
| `<start>`, `<length>` | The take time of the moment and `D`, in seconds |
| `[bars]` | How many bars (56) |

The real shot shows only while the card is flat. In 3D the card is the plate and the cutout, so the plate must match the footage.

The layout follows the frame:

- The panes are the full frame, so the layout is the same in every shape. The waveform sits near the bottom right; the title near the top left.

## How to make it for a video

The composition has four panes in CSS 3D: the room is a clean plate, the speaker is the cutout of the footage, the title is type, and the sound is a waveform from the take's audio. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.6 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/layer-explode/`.
3. Change `TITLE`, `LAYERS`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Make `layer-explode/plate.png` once, before the render: the room without the speaker, at `<W>`x`<H>`, framed like the footage.
   - Best: a frame of the take where the speaker is out of shot. Cut it with the same `-vf` as the footage step: `ffmpeg -y -ss <time> -i ../../<take file> -frames:v 1 -vf "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>" layer-explode/plate.png`.
   - Else: save a frame of the moment the same way as `layer-explode/frame.png`. Call the Takes `make_image` tool with `images` = that frame, `format` = the edit's shape, and a prompt like "the same room, same camera and light, with the person removed; fill in what is behind them". Then scale the image it returns to the frame: `ffmpeg -y -i <made image> -vf "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>" layer-explode/plate.png`.
   - Look at the plate next to the frame. Walls, edges and furniture must sit in the same place, or the room jumps when the plate comes on.
5. Add four steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step makes the waveform from the take's sound. The fourth step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "layer-explode/footage.mp4"],
      "makes": ["layer-explode/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "layer-explode/footage.mp4", "-o",
              "layer-explode/person.webm", "--quality", "best"],
      "makes": ["layer-explode/person.webm"]},
     {"run": ["python3", "layer-explode/wave.py", "../../<take file>", "<take time>", "<D>",
              "layer-explode/wave.js"],
      "makes": ["layer-explode/wave.js"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "layer-explode", "-q", "delivery", "-o",
              "layer-explode.mp4"],
      "makes": ["layer-explode.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
6. Add the layer: `"over": [{"file": "_edit/<name>/layer-explode.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
7. Run `render_edit`, then `check_edit`. Look at a frame when the panes are apart. Each pane must show its layer and label, and the room pane must show no speaker.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9.
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- `wave.py` needs Python 3 with numpy.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Fonts: IBM Plex Mono and Old Standard TT, SIL Open Font License 1.1 (`src/fonts/OFL-*.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
