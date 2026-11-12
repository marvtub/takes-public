# Post wall

## What it does

The shot punches in a little and the room gets darker. A wall of small squares comes up behind the speaker's head, like a contribution graph, on a dark panel. It fills in from the bottom row up. The newest row flashes cream, then settles into greys, deep green and gold. A few cells at the bottom right stay empty: the days still to come. Above the wall a day counter and a big post count run up together. At the end the count turns gold and the small legend square pulses. The head stays in front of the wall. Then the wall snaps away.

Use it only when the user asks for it.

## What to change

All values are at the top of the script in `src/index.html`:

| Value | What it controls |
|---|---|
| `DATA.days`, `DATA.posts` | The numbers the day counter and the big count run up to |
| `DATA.unit` | The word after the count |
| `WALL.cols`, `WALL.rows` | How many cells across and down |
| `WALL.empty` | The part of the cells that stays empty at the bottom right (0 to 1) |
| `WALL.x`, `WALL.y`, `WALL.w` | Where the wall sits: left edge, top edge and width, as parts of the frame. The height follows from the rows |
| `WALL.seed` | Changes the random pattern of colours. The same seed gives the same wall in every render |
| `LOOK.mix` | The colours of filled cells, each with how often it is picked |
| `LOOK.gold`, `LOOK.flash`, `LOOK.empty`, `LOOK.line` | The gold of the count, the flash of the newest row, the colour and outline of empty cells |
| `LOOK.dim`, `LOOK.panel`, `LOOK.punch` | How much the room darkens (0 to 1), the panel colour behind the wall, the punch-in (1 = none) |
| `AT` | When the wall shows (`in`), when the fill starts (`fill`) and how long it runs (`fillFor`), when the wall goes (`out`), in seconds |
| `data-width`, `data-height` | The frame size, on `#root`. The script reads it as `FRAME`. Set both to the edit's size: 1080x1920 (9:16), 1080x1350 (4:5), 1080x1080 (1:1) or 1920x1080 (16:9) |
| `data-duration` | The length of the effect in seconds, on `#root` (3.4 s now). The times in `AT` are seconds from its start |

The dark panel keeps the count readable in a bright room. Set `LOOK.panel` to `"transparent"` for no panel.

The layout follows the frame:

- Tall (9:16, 4:5): the wall spans the width above and behind the head (`WALL.w` 0.84).
- Square and wide (1:1, 16:9): the wall height follows its width, so at 0.84 it is taller than the frame. Set `WALL.w` to about 0.4 to 0.5 and put the wall beside the head with `WALL.x`, or use fewer rows.

## How to make it for a video

The composition has the footage, the wall, and the speaker cut out of the same footage in front. The render is a full-frame layer.

1. Pick the cut time `T` where the effect starts and its length `D` (3.4 s now; keep the times in `AT` inside it). The window must be inside one entry of the recipe's `cut`.
2. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/post-wall/`.
3. Change `DATA`, `WALL`, `LOOK` and `AT`. Set `data-width` and `data-height` on `#root` to the edit's size, and `data-duration` to `D`.
4. Add three steps to the recipe. The first step cuts the footage of the moment. The second step cuts the speaker out of it (the matte). The third step renders the layer:

   ```json
   "steps": [
     {"run": ["ffmpeg", "-y", "-ss", "<take time>", "-t", "<D>", "-i", "../../<take file>", "-vf",
              "scale=<W>:<H>:force_original_aspect_ratio=increase,crop=<W>:<H>,setsar=1,fps=<fps>", "-an",
              "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "post-wall/footage.mp4"],
      "makes": ["post-wall/footage.mp4"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "remove-background", "post-wall/footage.mp4", "-o",
              "post-wall/person.webm", "--quality", "best"],
      "makes": ["post-wall/person.webm"]},
     {"run": ["npx", "--yes", "hyperframes@0.8.214", "render", "post-wall", "-q", "delivery", "-o",
              "post-wall.mp4"],
      "makes": ["post-wall.mp4"]}
   ]
   ```

   `<take time>` is the cut entry's `in` plus (`T` minus the time where that entry starts in the cut). `<W>` and `<H>` are the edit's frame size (the same numbers as `data-width` and `data-height`). `<fps>` is the edit's frame rate. If the recipe has `frame.crop`, put `crop=w:h:x:y,` before `scale` in `-vf`.
5. Add the layer: `"over": [{"file": "_edit/<name>/post-wall.mp4", "at": T}]`. Do not set `alpha`: the layer is full-frame.
6. Run `render_edit`, then `check_edit`. Look at the last frame before the wall goes. The count must read, and the head must cover only the lower part of the wall.

The steps run on every render. The matte takes about 4 s for each second of footage on an Apple silicon Mac. To save time, run the steps before the render once (as a job) and keep only the render step in the recipe.

## Limits

- Works in 9:16, 4:5, 1:1 and 16:9 (see the layout above).
- It needs a shot with one person and a background that is clear of other people. The matte is made for people. It can miss things the person holds, and fine hair can get a soft edge.
- Use real numbers. The wall pattern is random: it does not show real days.
- The full-frame layer covers the cut for `D` seconds. If the window crosses a cut point, the footage in the layer does not match the edit. Move the effect.
- The render needs Node.js (for `npx`), Chrome (HyperFrames downloads it on the first run) and ffmpeg. It loads GSAP from a CDN, so it needs the network.

## Credits

- Made for Takes. Our own layout and motion.
- Cutout: `hyperframes remove-background` (HyperFrames, Apache-2.0). It runs on the Mac with no key. On the first run it downloads the `u2net_human_seg` model (176 MB, from the rembg project, MIT; U²-Net, Apache-2.0) to `~/.cache/hyperframes/background-removal/models/`.
- Font: IBM Plex Mono, SIL Open Font License 1.1 (`src/fonts/OFL-IBMPlexMono.txt`).
- Animation: GSAP 3, loaded from jsDelivr (free GSAP licence). Renderer: HyperFrames (Apache-2.0).
