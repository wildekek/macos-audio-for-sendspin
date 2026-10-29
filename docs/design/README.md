# Design

UI of any real scope is designed here before it's built: options and every state on a canvas, iterated until settled, then built. This folder is that canvas as published, and the scripts that draw its boards.

The canvas: https://claude.ai/artifact/RNVdDCaACSNvQbJHMe5azE (a Design artifact, "Sendspin menu redesign").

## What's here

- `canvas/project/canvas.json`: the canvas's index: where each board sits, its title, and the section titles (`notes`).
- `canvas/project/*.dc.html`: the boards, one file each, as published. The early ones (`Today`, `Approach*`, `RowStates*`, `MacInMA*`, `Main`) were made on the canvas itself and have no script.
- `generators/gen_*.py`: the scripts that draw the later boards. They share their helpers (a row, a check, the icons, a board) so every board looks the same, and options differ only in what they're about:
  - `gen_pairing.py`: pairing a speaker by code (the base helpers live here).
  - `gen_token.py`, `gen_camera.py`, `gen_cta.py`, `gen_window.py`, `gen_scanwin.py`: the pairing token, the camera, and the scan window.
  - `gen_inputs.py`: the first Source placements (I1–I3) and allowing a source.
  - `gen_sources3.py`: three sources without play buttons (P1–P4).
  - `gen_sources_blue.py`: Source by the menu's own rule (P5, chosen).
  - `gen_macplayer.py`: the Mac as a speaker for another server, with Source.
  - `gen_sources_ma.py`: Source while Music Assistant is chosen (M1–M5).
  - `gen_status.py`: the menu bar icon and the dot, as built.
  - `gen_icons.py`: the app icon and the menu bar icon with the Sendspin mark (A1–A3, M1–M2), from `App/sendspin-logo.svg`. The speaker icons of 0.10.x are uploads on the canvas (`/_blob/…`): boards can't carry `data:` images.
  - `gen_motion.py`: the menu bar icon in motion, with a Play/Stop button (interactive).

Settled decisions are in the boards' titles ("chosen") and in `menu-states.md`.

## Changing a board

1. If the canvas was changed on claude.ai since the last publish, read it back into `canvas/` first, so nothing is overwritten.
2. Edit the generator and run it from anywhere: `python3 docs/design/generators/gen_sources_ma.py`. It writes its boards and their places into `canvas/project/`.
3. Look before publishing: `qlmanage -t -s 1600 -o <dir> docs/design/canvas/project/SourcesMA2.dc.html` renders a board to a PNG (wide boards are cropped on the right).
4. Publish to the same canvas with the Artifact tool: `root` is `docs/design/canvas`, `file_path` is `docs/design/canvas/project/canvas.json`, and `files` lists the boards that changed.
5. Commit the changes here with the code they're for, or on their own.
