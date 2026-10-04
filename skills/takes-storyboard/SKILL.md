---
name: takes-storyboard
description: Turn a video idea into a Takes session with a script and a sketch storyboard, so the user sees how to film it before they start. Use when the user brainstorms or rambles about a video idea, says "storyboard this", "plan this video", "how would I film this", or presses "Storyboard this video" on the Storyboard tab in Takes. Writes script.md, then calls set_storyboard (takes MCP), which draws one marker sketch per shot in the background and shows them on a timeline with the script lines under each shot.
---

# Takes storyboard

The storyboard helps the user plan a shoot. The sketches are low fidelity on purpose. They show
who is in the frame, where the camera is, and what moves. They are not the final look.

## Before you start

- The sketches need a Gemini API key: `GEMINI_API_KEY` or `GOOGLE_AI_API_KEY` in the environment
  or in `~/.claude/.env`. Without one, the shots still save, but each shows an error instead of a
  drawing. Tell the user in one line if that happens.
- All work goes through the `takes` MCP. Never write `session.json` or `storyboard/` by hand.

## Steps

1. **Session.** In a Takes chat, the session is given. From a terminal, call `create_session`
   with `project`, `title` and `script`. If the project is unclear, ask. Do not storyboard into a
   session that already has takes, unless the user asks.
2. **Script first.** Write `script.md` with `create_session` or `update_session` (give a short
   `note`). Short spoken sentences. The hook is the first paragraph. Aim for about 45–75 s unless
   the user says otherwise. After each paragraph, add one direction line in brackets, for example
   `[DESK, to lens. A stack of papers next to the laptop.]`.
   For several opening options, call `set_hooks` with `[{text, note}]`. Keep your best hook as the
   first paragraph of `script.md`.
3. **Shots.** One shot per paragraph, sometimes two. Usually 6–12 shots in three sections. The
   Storyboard tab shows each section as its own row:
   - `hook`: the opening 3–8 s, one or two shots. Other openings go in `set_hooks`, not here.
   - `main`: the body.
   - `end`: the last line and the call to action. A shot of kind `END` goes here.
4. **`set_storyboard`** with `session` and the full `shots` list. It returns at once. The sketches
   draw in the background (about 30 s each, a few at a time) and the tab fills in.
5. **Reply** in two or three lines: the idea in one sentence, the shot count and the length, and
   "Open the Storyboard tab". Do not list the shots in chat. The tab shows them.

## A shot

| Field | What to write |
|---|---|
| `id` | Leave it out for a new shot. When you change a shot, pass its id from `get_session` (`storyboard`). Takes and comments point at it. |
| `section` | `hook`, `main` or `end`. Default `main`. |
| `kind` | `DESK` (seated, to lens), `WALK` (standing or outside), `B-ROLL` (footage, hands, objects), `SCREEN` (screen recording), `MG` (motion graphic), `END`. |
| `say` | The script lines this shot covers, **word for word** from `script.md`. |
| `do` | How to film or build it, in one short line: framing, lens, prop, camera move. |
| `sketch` | What the drawing shows. It is the prompt for the image model. See below. |
| `video` | Optional. A real clip shown instead of a drawing: a file from `list_broll` (the MCP adds it to the session's `broll/`), or a path in the session such as `edits/x.mp4`. |
| `seconds` | Leave it out. The app counts from the words in `say`. Give it only for a shot with no words. |
| `redraw` | `true` draws the same sketch text again (for a bad drawing). |

For a `B-ROLL` shot, check `list_broll` first. If a clip in the user's library fits, put it in
`video` and name it in `do`, so the user does not film it again.

## How to write `sketch`

The style is fixed in the MCP: black marker on white paper, one blue marker for motion, faceless
round-head figures, no text. Write only what is in the frame:

- **Name each thing plainly and say how many.** "One person", "a laptop", "a box full of paper
  receipts". The model fills in anything you leave vague, often with extra people or cameras.
- **Say the framing.** "Medium shot", "close-up of two hands", "seen from the side".
- **Show motion and camera moves as arrows.** "A curved arrow shows the lid closing", "corner
  marks show the frame slowly pushing in".
- **Draw motion graphics as simple shapes.** Boxes, icons, rows, a folder tree, arrows. Describe
  the shape, not the brand: "rectangular cards, each with a circle logo", not a product name.
- **End every `MG` sketch with "No people. Nothing else in the frame."** Without it, the model
  tends to add figures next to the diagram.
- **Never ask for words in the frame.** Text comes out garbled. If a label matters, put it in
  `do`, not in `sketch`.
- Keep the cast small. Assume the user films alone (phone or Mac camera, a desk, a room, a walk)
  unless the idea needs someone else.

## Takes and comments per shot

The user records a take per shot with the Record button under a shot. In `get_session`, the
take's `shot` field holds the shot id. A storyboard take may also carry a `best_cut` suggestion
(`by: gemini`). Treat it as a first guess: check it against the transcript and the frames at both
ends, then call `set_best_cut` (`session`, `take`, `start`, `end`, `why`, optional `said`,
`clean`) with the range you would use.

The user can also comment on a shot. `get_comments` returns these with `shot`, `shot_now` (the
shot as it is now) and `frame` (the sketch). To fix one:

1. Change the shot with `set_storyboard` (the full list, every id kept).
2. If the lines change, update `script.md` too (`update_session`).
3. Call `reply_comment` once for all comments: `replies: [{id, text, resolve: true}]`, one line
   of text each. If a comment is unclear, reply with a question and leave it open.

## Changing a storyboard

- `set_storyboard` replaces the whole list. Always send every shot, each with its `id`.
- **Change only the shots the user names.** `get_session` does not return the sketch text, so
  first read `<session>/storyboard/storyboard.json` and copy every other shot's `sketch`, `say`,
  `do` and `video` exactly. An unchanged `sketch` keeps its drawing. A changed one is drawn again.
  A missing `video` is dropped.
- If you remove a shot that has takes, the result warns you. Give its id to the shot that
  replaces it.
- A script change: update `script.md` first, then the `say` of each shot it touches.
- A real clip for a shot ("use the b-roll we have"): set the shot's `video`. Never paste a frame
  over a sketch PNG.
- A shot shows an error (no key, quota): tell the user the reason in one line.

## Where it lives

- `<session>/storyboard/storyboard.json` and one PNG per sketch. Write it only with
  `set_storyboard`.
- Shot comments live in the session's comments with file `storyboard/storyboard.json` and a
  `shot` id.
- Sketches are drawn at 4:5.
