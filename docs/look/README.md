# docs/look — the sign-off canon

Reference renders the world view is judged against. Regenerate with the
look probe (needs a real display — the main viewport texture is unreadable
headless, the probe hangs there):

```sh
GODOT=../infrastruct/.tools/godot/Godot_v4.7.1-stable_linux.x86_64
for z in 17 44 120; do
  DISPLAY=:0 SHOT_ZOOM=$z "$GODOT" --path game -- --screenshot=docs/look/zoom_$z.png
done
"$GODOT" --path game -- --smoke=model_gallery --shot=docs/look/model_gallery.png  # DISPLAY set
```

`SHOT_TILE="x,y"` aims the probe anywhere (Alps 391,550 · Geneva 364,546 ·
Ladoga 708,221 · Norway coast 350,212 — the relief showcase spots).

| file | what to check |
|---|---|
| `zoom_17.png` | boot zoom: city blocks, plant models, pylons crisp; haze only in the top quarter |
| `zoom_44.png` | working zoom: corridors readable, forests thinning to visibility flag range |
| `zoom_120.png` | strategic zoom (MAX_ZOOM): whole frame visible — **any full-frame haze is the fog-band regression** `test_world_view.gd` pins; coastline shape recognizable, sea depth-graded |
| `model_gallery.png` | every buildable component on the labelled grid |

Relief checks (ETOPO sidecar, `tools/map_authoring/relief.py`): smooth
shorelines (no tile staircase), snow above the Alpine treeline, lakes blue
in their valleys (Geneva is the hard case — a coarse-backdrop regression
buries it), green farmed plains vs dry Mediterranean, forest tint matching
the scattered tree cover.

Captured 2026-08-21 (M1, derived fog band). The three zooms are the pinned
set from `test_world_view.gd`'s ZOOMS that a screenshot can meaningfully
show; the invariants themselves live in that suite.
