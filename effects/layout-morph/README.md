# Layout morph

## What it does

The screen recording fills the frame and you sit over it in a box. The box can be a rounded 16:9 card in a corner, a round bubble in a corner, a tall panel at the side (at the bottom in a square or tall frame), or the full frame. At each change in the plan, the box glides into the next layout: its place, its size, its corner radius and the crop of your camera all ease together in 0.7 s (cubic in and out), and a dark panel slides in or out behind it for the side layout. Your face stays in the middle of the box the whole time.

Each change gets a short real whoosh at its fastest point (`src/whoosh-1.wav` to `whoosh-3.wav`, three slight pitches of one recording). Use these, not a whoosh or swipe from the Sound FX bank: made-in-code swipes on these moves sounded harsh to people.

It is one layer: `src/morph.py` draws it as a see-through video for the recipe's `over`. Use it only when the user asks for it, or when their rules say so. Everyone grows their own style.

## What to change

| Value | What it controls |
|---|---|
| `--plan` | `[{"at": 0, "layout": "card"}, {"at": 9.5, "layout": "bubble", "corner": "bl"}, ...]`: seconds of the layer and the layout from then on. The first entry is the opening layout. Layouts: `card`, `bubble`, `side`, `full`; `corner` (`br`, `bl`, `tr`, `tl`, default `br`) for card and bubble |
| `--face` | The centre of your face in the camera file's pixels, `x,y`. Look at a frame of the camera |
| `MORPH_S` in `morph.py` | Seconds of each change (0.7) |
| `CROP` in `morph.py` | How much of the camera's height each layout shows around the face: less is closer |
| `layout()` in `morph.py` | The size and place of each layout, as shares of the frame, so every shape works |
| `PANEL_RGB` | The colour of the side panel |
| `WHOOSH_GAIN` | The whoosh's level in the mix, in dB (-11: under the voice) |

**Each shape.** The layouts are shares of the frame: in 16:9 the side panel is the right third, in 9:16, 4:5 and 1:1 it is the bottom 42%. Card and bubble sit in a corner with a margin of 3.5% of the shorter side.

## How to make it for a video

1. Get the take's files from `get_session`: `take-NN-camera.mov` and `take-NN-screen.mov`. The recipe's `cut` uses the screen file (`"kind": "screen"`).
2. The camera file starts at another moment than the screen file. `get_session` shows `screen_lag_s` on the screen take: the camera time of a moment is its screen time minus `screen_lag_s`. For a screen part with `in` = `a`, `--start` is `a - screen_lag_s` (below 0 holds the first camera frame).
3. Look at a frame of the camera and pick `--face`. Pick the change seconds with the user: where they start to talk to the lens, where the screen matters.
4. Copy this effect's `src/` folder into the edit's folder as `_edit/<name>/layout-morph/`.
5. In `_edit/<name>/`, run it once with `--dry` to get the sounds: it prints `{"layer", "at", "changes", "sfx"}`. Then add the step, the layer and the sounds to the recipe. `<W>` x `<H>` is the edit's size, `<fps>` its frame rate, `<length>` the cut's length:

   ```json
   "steps": [
     {"run": ["sh", "layout-morph/morph.sh", "--camera", "../../<take>-camera.mov", "--out", "morph.mov",
              "--size", "<W>x<H>", "--fps", "<fps>", "--start", "<start>", "--length", "<length>",
              "--face", "<x>,<y>", "--plan", "<the plan as JSON>"],
      "makes": ["morph.mov"]}
   ],
   "over": [{"file": "_edit/<name>/morph.mov", "at": 0, "alpha": true}],
   "sfx": [<the printed sfx entries, after the sounds already there>]
   ```

   For a cut of several parts, make one layer per part (one step each, `at` and `--at` = where the part starts in the cut).
6. Run `render_edit`, then `check_edit`. Look at a frame in each layout and one in the middle of each change.

## Limits

- The box shows a crop of the camera around one fixed face centre. If you move a lot, use a bigger `CROP` for that layout.
- `morph.sh` runs `morph.py` with numpy and OpenCV through uv, like Takes' voice cleanup (Takes installs uv the first time you clean a voice). The first run downloads Python 3.11 and the two packages, so it needs the network once; later runs work offline.
- About 1.5 s of drawing per second of 1080p video on an M-series Mac.
- The layer's own sound is never used: the voice comes from the cut, the whooshes from `sfx`.

## Credits

- Made for Takes. Our own look. A camera box that changes layout is a common technique in screen recordings.
- Whoosh: a whoosh by 1bob, https://freesound.org/s/831936/ (CC0 1.0). Cut off below 150 Hz, three slight pitches, set to -1 dBFS peak.
- Previews: a made-up Takes screen and a drawn stand-in, not a real person.
