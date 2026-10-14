# YamVideo editor concept

Open `index.html` directly in a browser, or serve this directory with:

```sh
python3 -m http.server 8766 --bind 127.0.0.1
```

Visit `http://127.0.0.1:8766`. There is no installation or build step, no external font
or asset request, and no backend. All artwork is original SVG included here.

Try colour sliders, Original/Corrected/Compare, timeline seeking and splitting, section
speed, undo/redo, the Local agents demonstration, timed blur, Movie view and the export
sheet. The “What can I try?” guide is available inside the prototype.

This is an interaction prototype, not the native editor: artwork is static, playback
moves a simulated playhead, colours use CSS rather than DJI LUTs, agents are simulated,
and Export does not encode a file. Added files contribute names only and are neither
uploaded nor decoded. Demo edits reset on reload. Later-phase effects are included for
visual review without changing the implementation sequence in the coordinating plan.

The real app must implement frame-accurate source anchoring/remapping, colour management,
atomic commands, conflict detection and persistence from the implementation documents;
this browser demo is not a reference implementation of those algorithms.

## Verification

Checked in the Codex in-app browser on 2026-10-14: colour adjustment/comparison,
split and section speed, simulated agent edit/conflict/pause, shared undo including
keyboard undo, blur add/preview, Movie view and the export sheet. No browser console
errors were reported in these flows. Reviewed the 1360 × 880 desktop layout and checked
390 px width for horizontal overflow. JavaScript syntax and local document/asset links
were checked separately. The standalone Playwright CLI could not launch because Google
Chrome is not installed; browser verification used the available in-app browser instead.

Rechecked on 2026-10-14 after fixing slider undo: ⌘Z/⇧⌘Z work directly from a focused
slider and keep its focus; a held arrow key or one drag is one undo step; a drag released
at its starting value records nothing and cannot fold a later edit into another's undo.
⌘Z inside the trim fields stays with the field.
