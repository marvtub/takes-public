# Screen zoom

## What it does

The screen recording zooms in on what you do. Before each click, the view eases in (0.6 s) so the click happens close up. While you work, the view follows the pointer: it holds still while the pointer stays in the middle half of the view and pans in one calm move when it leaves. After your last click it eases back out (0.8 s). The view never shows past the edge of the frame.

The zoom works on the screen recording at its own size, before the crop and the scale to the frame. A 2x Retina screen keeps its sharp text when zoomed in. The drawn pointer zooms with the screen. Picture layers (your camera bubble, captions, key badges) stay as they are.

It is two recipe options of `render_edit`, no step to run: `zoom` and the pointer's look. Use it only when the user asks for it, or when their rules say so. Everyone grows their own style.

## What to change

`zoom` in the recipe:

| Value | What it controls |
|---|---|
| `auto` | `true`: Takes zooms in on each run of clicks of a screen part. Clicks less than 3 s apart are one zoom. It starts 0.9 s before the first click and ends 1.6 s after the last |
| `spans` | Your own zooms: `[{"at": 4.0, "end": 9.5}]` in seconds of the cut. Pick them from what the voice says ("now I open Settings"). With `"x"` and `"y"` (shares of the frame, 0 to 1) the view holds on that point; without them it follows the pointer. Each is 1.4 s or longer. Used with `auto`, Takes adds its zooms where yours are not |
| `level` | How close: `2` shows half the width. Default `1.8`, from `1.1` to `4`. A span can have its own `level` |
| `follow` | `false`: the view goes in on the first click and holds there |

`pointer` in the recipe (the drawn pointer of screen takes recorded with the cursor log):

| Value | What it controls |
|---|---|
| `look` | `"system"` (default): the Mac's own shapes (arrow, I-beam, hand). `"dot"`: a white disc with a thin dark edge, like a touch. A `.png` in the session or the library (`@library/...`): your own picture for every shape, as tall as the Mac arrow |
| `size` | Scales the look: `1.5` is half again as big. From `0.5` to `4` |
| `hot` | For a `.png` look: the tip, `[x, y]` in the picture's pixels. Default the top left |
| `smooth` | An eased path, exactly on the click at click time |
| `hide_idle` | Fades the pointer out after 2 s without a move |

**Each shape.** The zoom is worked out in the edit's frame, so it works for 9:16, 4:5, 1:1 and 16:9 and any `frame.crop`.

## How to make it for a video

1. The recipe's `cut` must show the screen take (`"kind": "screen"`). `get_session` shows its cursor log as `events` under the screen take.
2. Add the options, for example `src/recipe.json`: `"zoom": {"auto": true}` and, if asked, a pointer look.
3. Run `render_edit`. The recipe gets `zooms`: each zoom Takes made, `{at, end, level, follows, why}`. Tell the user in one line each where it zooms and why ("0:02 to 0:08, on the Share click").
4. Run `check_edit`. Look at a still just before each click (close up, the click target in view) and one after the zoom ends (the whole screen).
5. To change one zoom, give `spans` (and drop `auto` if Takes' other zooms should go too).

**With the click ring.** `render_edit` writes the view of each zoomed frame to `_edit/<name>/zoom.json` before the steps run. Run the click ring's `clicks.py` as the first step with `--zoom zoom.json`, so each ring sits where the zoomed screen shows the click.

## Limits

- `auto` and following the pointer need a cursor log. Screen takes recorded before 2026-10-30 have none: give `spans` with `x` and `y`.
- `zoom` and `frame.crop.follow_face` do not go together.
- A zoom stays inside one part of the cut: at a cut it is out again.
- The export to an editor (FCPXML) leaves the zoom out: it is only in the mp4.

## Credits

- Made for Takes. Our own code. Zooming a screen recording on clicks is a common technique in screen video apps.
- Previews: a made-up notes app, not a real screen.
