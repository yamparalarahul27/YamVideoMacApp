# Thumbnails: the science of a click

**Status (2026-10-19):** Part 1 (phone check,
[PR #54](https://github.com/yamparalarahul27/YamVideoMacApp/pull/54)) and part 2
(information gap, [PR #55](https://github.com/yamparalarahul27/YamVideoMacApp/pull/55))
are merged, and so is part 3 (eye path,
[PR #56](https://github.com/yamparalarahul27/YamVideoMacApp/pull/56)). Part 4 (Test & Compare) is
built, in [PR #57](https://github.com/yamparalarahul27/YamVideoMacApp/pull/57). The owner asked for each part after the one before it.
**Source:** the backlog item of 2026-10-18, from "Science Behind Thumbnails That Actually
Work." by HimanshuG (https://youtu.be/9_7q6vUaRsM). Its rules: a viewer decides in 0.5 s,
a thumbnail opens a question the title does not answer, the eye goes to the face first and
then to the biggest words, and YouTube's Test & Compare tries up to three thumbnails.

The work goes into the thumbnail maker (Publish… → Make Thumbnail). Each part is one PR.
Each new tool is also an agent command, in the catalog and in the Agents Manual.

## The order

1. **Phone check.** The other parts use what it measures: the boxes of the words, the size
   of the letters and the place of the face.
2. **Information gap.** It uses the phone view, because the phone shows the title under the
   thumbnail.
3. **Eye path.** It uses the word boxes and the face box from part 1.
4. **Three versions for Test & Compare.** It is the only part with new saved data, so it
   comes last, when the checks can compare the three versions.

## Part 1: phone check

What the owner sees:
- The preview area gets two views: **Design** (the large live preview, as now) and
  **Phone**. Phone shows the thumbnail at the size of an iPhone's YouTube home
  feed (390 × 219 pt, with the title and channel under it) and of a search list row
  (168 × 94 pt, with the title beside it).
- Under the preview, a **Phone check** list says what does not read in 0.5 s. Each
  finding is one short line (for example "Title too small: 8.9 pt in the search list");
  the full advice shows on hover, and under the line after a click. The counts at the top
  are icons with numbers. The check runs again about 1 s after each change.
- **Thumbnail**, under **Studio** in the left bar, opens the maker without the Publish
  window, from any page; so does **Go → Make Thumbnail…** (⇧⌘T). (Owner, 19 Oct 2026: the
  Publish route was hard to find, the Library and Calendar pages have no Publish button,
  and the maker belongs under the Studio.)
- The maker's labels are short (owner, 19 Oct 2026: no long button text): Save, Phone,
  Highlight, Cut-out, Outline, Place: Clear, Title side: Auto, Picture. Long help text
  moved into tooltips.
- The old "At YouTube's search size" preview (a desktop size) goes. The phone sizes
  replace it. The sheet is 1200 pt wide (was 1060), so the search list row has the
  phone's real width.

What the check measures (all from the drawn thumbnail, not from guesses):
- **Text too small:** the size of the letters of the tag, the title and any text in the
  picture beside the title (read with Apple Vision), in points on the phone. 12 pt or more
  reads; 9 to 12 pt is weak; less than 9 pt does not read. The tag has a fixed size and is
  a small label, so a small tag is only weak.
- **Too many words:** the words of the tag, the title and the picture. Up to 5 words read
  in 0.5 s; 6 to 8 words are weak; 9 or more do not read.
- **Low contrast:** each run of words against what is behind it, in the finished picture
  (the title's shadow counts). The thumbnail is drawn a second time with the title's
  letters in pure magenta and no shadow, so the check can leave the letters out. (Letters
  made see-through do not work: at 2× WebKit leaves out their shadow.) Behind light words
  the brightest tenth counts, and behind dark words the darkest tenth. Words in the
  picture use the two tones inside their box. A
  contrast of 4.5:1 or more reads; 3 to 4.5 is weak; less than 3 does not read. Words on
  their own colour band (the tag, highlighted words) use the band's colour.
- **Face too small:** the speaker's face (found with Apple Vision), after the speaker's
  size and place, in points on the phone. 24 pt high or more reads; 16 to 24 pt is weak;
  less than 16 pt does not read. No face found is also a weak point.

The limits are constants in `Sources/ThumbnailCheck.swift` (`PhoneCheck`), so they are
easy to change after the owner tries them on real thumbnails.

First result on the AgentUX Part 1 thumbnail: the title is 8.9 pt in the search list
(fails, just under 9 pt), the badge names are 3.7 pt (fails), 15 words (fails), the tag
is weak, and the face reads at both sizes. The check took about 1.3 s. (Part 2 makes it
14 words: Apple Vision read a logo as "g", and one letter alone is no longer a word.)

For agents: the `thumbnail` request gets `check: true`. The result then has `check`: the
findings (kind, level, the phone sizes, a message), the word count, the title's letter size,
the face's box, and `phone`, a PNG of the design at both phone sizes.

Saved data: none. The check is calculated each time.

## Part 2: information gap

What the owner sees:
- A **Video title** field in the maker, above the **Thumbnail title** (the old "Title"
  section). The phone view shows the video title as you type. **Save** keeps it with the
  design, in the same undo step.
- Under the thumbnail title, one short line that changes as you type: "Repeats the video
  title: “…”" (orange), "Only repeats the video title" (red), or "Adds: …" (green). The
  advice (let these words add what the title does not say: the result, a number, a
  surprise or a question) shows on hover.
- The check list (now **Thumbnail check**) has the same finding.

The rules (`InformationGap`, `Sources/ThumbnailGap.swift`):
- Words compare without case, plurals, possessives and asterisks. Small words ("the",
  "for", "how", "my" and the like) do not count as repeats.
- The thumbnail's words are the tag, the title and the lines read in the picture.
- A shared phrase is a run of words in the same order, with two important words or four
  words in all. A run stops at punctuation in the title (a colon, a bracket) and at the
  end of the tag, the title or the picture.
- Fails: the thumbnail has two important words or more, and all are in the title. Weak: a
  shared phrase, or more than half the important words in the title.

For agents: the `check` result gets the finding (kind `title`, no sizes) and `gap`: the
title compared, the repeated words, the phrases, the added words and the overlap.
`videoTitle` (`--video-title`) tries another title without storing it.

Saved data: none. The title is already in the publish details.

First result on the AgentUX Part 1 thumbnail: weak. It repeats "System design for
designers" and "how I built my own", and adds ENGINEERING, Supabase, Claude and Figma.

## Part 3: eye path

What the owner sees:
- A third view above the check list: **Design | Eye path | Phone**. Eye path shows the
  checked picture with a numbered mark just left of each stop (at its middle height, so
  the words stay clear), joined by a dashed line in order. The mark of the coloured words is yellow. It shows 5 stops at
  most. A tooltip on each mark names the stop. (The live Design preview stays clean.)
- A weak finding when the coloured words are not 1st or 2nd, for example "Eye path:
  “viewer” is 3rd"; the advice on hover says what comes first and what to change.

The rules (`EyePath`, `Sources/ThumbnailEyePath.swift`):
- The face is always 1st when it shows.
- Then each run of words (the tag, plain title words, coloured words, each line in the
  picture) by its pull: letter size × clarity × colour. Clarity is the contrast over
  4.5:1, at most 1. Colour: 1.15 for accent words, 1.3 for a band of the accent (not the
  tag). At the same pull, the larger box comes first.
- The important part is the words between asterisks. With none, there is no warning.

For agents: the `check` result gets `path` ([{step, kind, text, box}]) and the finding
(kind `eyePath`, no sizes).

Saved data: none.

## Part 4: three versions for Test & Compare

What the owner sees:
- In the maker's header: **+ Version** adds a copy of the version shown, to change (up to
  3). With more than one, an **A | B | C** switch shows each, and **−** removes the one
  shown (not A). The check, the eye path and the phone view work on the version shown.
- **Save** makes a PNG of each version, with its letter in the name ("… thumbnail B.png"),
  and keeps them in one undo step. A winner already marked stays the thumbnail.
- After a save, a **Winner** menu (None, A, B, C). Marking a version makes its picture the
  thumbnail (one undo step), and adds a line to the notes of the project's idea in the
  Library, like "Thumbnail test, 2026-10-19: B won of 3 (“3 rules”)." So the Library keeps
  the result for the next videos.
- **Export for YouTube** also writes "… thumbnail A.jpg", B and C (1280×720, under 2 MB).
  The text file has a THUMBNAIL TEST & COMPARE section with the files and the winner, and
  the JSON has `thumbnailTest`. A missing version picture stops the export; versions not
  yet saved are a warning.

Saved data (version 19): `PublishInfo.test` (`ThumbnailTest`): `versions` (B and C; A is
`design`), `images` (each version's PNG, A first, after a save) and `winner` (0 is A).
`VideoProject.currentVersion` is 19, and a file of version 18 or older that holds a test is
refused. A version's frame follows its footage through cuts, as the design's does.

For agents: `setPublishInfo` with `{test: {versions, images, winner}}` (only the keys given
change; a winner makes its image the thumbnail unless `thumbnail` is given too), and
`thumbnail` with `version` (A, B or C; `--version`), which `save` names with its letter.
The Agents Manual (4.7 Thumbnail, step 7) gives the order.
