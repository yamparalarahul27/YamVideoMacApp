# Studio redesign: Filmora-style proposal

Open `index.html` in a browser. No build step and no server.

The page puts YamVideo's Studio next to a proposal that takes Filmora's timeline, crop,
player and property panel. It has five areas, a shortcuts table, an order of work and
six questions for the owner.

- **Before** pictures (`img/now-*.jpg`) are real renders of the app on main (9498061), made
  with `Tools/Snapshot/snapshot.sh` and `DJI_20261014194430_0007_D.MP4`.
- **Proposed** is a clickable mockup. Its frames (`img/p*.jpg`), waveform and captions
  come from that recording. Its sections, zooms and graphics are example data.
- **Step** pictures (`img/step1-*.jpg`, …) are real renders of the app after each step.

The **Tracker** at the top of the page keeps the history of the UI. Its data is the
`tracker-data` JSON block in `index.html`: one entry for each step (status, branch, pull
request, what is done and what is left) and one for each version of the app, with a real
picture made by the snapshot tool (`img/step1-editor.jpg` and so on). When a step ships,
add its pictures and update its entry, so the Before, P1, P2… buttons in the editor
show how the Studio changed.

Things to try in the mockup: split on the playhead, Crop with Apply, Speed, the switches
in the inspector, Before/After, and ⌘Z.

The Filmora facts come from the Filmora 15 and 16 Mac guide, read on 19 October 2026.
The page links to the guide pages.

Checked on 19 October 2026 in the in-app browser at 1360 px and 375 px, in light and
dark: split, crop, speed, delete, undo and the switches work, with no console errors and
no sideways scroll. The fonts load from Google Fonts; without a network, the page uses
the system fonts.
