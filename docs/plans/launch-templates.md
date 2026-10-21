# Launch templates and YouTube numbers

**Status (2026-10-21):** plan only. Research done and the owner's two decisions are in.
Nothing is built yet. Each part is its own chat and its own pull request, in the order of
section 6.

## 1. What the owner asked (2026-10-21)

The owner asked for research on two GitHub repositories:

- [Panniantong/Agent-Reach](https://github.com/Panniantong/Agent-Reach): to get a
  published post's numbers and new comments from its link. "I will be giving you the link
  once it is published."
- [latent-spaces/brag](https://github.com/latent-spaces/brag): videos that feel more
  interactive, for Shorts that launch a product, "so we might use some of the key
  details from it".

Both were read on 2026-10-21 (nothing installed or run). The answers that followed:

1. **Yes**: read the public numbers of the owner's own YouTube posts from a link, with no
   sign-in. Style.md's platform rule now says so.
2. "We'll be having all of these as templates in the app to click and run": every idea
   taken from brag becomes a template in YamVideo that the owner picks, fills in and runs.

## 2. Agent-Reach: what it is and what we take

Agent-Reach fetches nothing itself. It installs other tools and gives an agent a skill
file that says which tool to run for each platform. MIT licence; about 100k stars; one
main author; last commit 2026-10-07; many open bugs say its commands are out of date.

| Platform | From a post's link | How | Sign-in | Risk to the owner's account |
|---|---|---|---|---|
| YouTube and Shorts | Views, likes, comment count, the comments | `yt-dlp` reads the public page | None | None. Heavy use can bring a "confirm you're not a bot" page |
| X | The post and replies; view count unclear | `twitter-cli` with the owner's session cookies | The real account | High: its own install guide warns of bans (`docs/install.md`, step 3) |
| Instagram | Not a single reel; the profile commands are broken (issue #821) | OpenCLI drives the owner's signed-in Chrome | The real account | High |
| LinkedIn | No single post | A browser on a saved sign-in | The real account | Highest: LinkedIn's terms forbid scraping |

Watch time and retention come from no tool: only YouTube Studio and each app's own
insights have them.

**Decision:** do not install Agent-Reach. Take its YouTube approach only: `yt-dlp`, never
with cookies or a sign-in. X, Instagram and LinkedIn numbers stay typed in by the owner
(or read from a screenshot, distribution phase 4), as before.

## 3. brag: what it is and what we take

`/brag` is an agent skill (Markdown instructions, about 135K tokens and 10 minutes a video)
that reads a project's code or site and writes a 15–25 s launch teaser as a one-off
HyperFrames composition, the engine YamVideo already uses. It renders 1080×1920 for
Shorts. Its videos are fully generated: no camera, no presenter. The interactive feel
comes from the product's screens rebuilt in HTML with faked taps, swipes, typing,
counting stats and toasts. MIT licence; sound effects CC0 (Kenney, OpenGameArt); its
music's licence is not documented (issue #59). It ships rules and sounds, not scene code.

What we take from it, as rules for our templates:

- **Shape:** hook (2–3 s), reveal (2–4 s), two or three highlights, punchline.
- **Show the product in use:** first a real app moment, then a rebuilt UI element, then an
  animated idea, and big type only when nothing else fits. Each highlight goes entry →
  key action → result.
- **Reading time:** at least 0.8 s for a short label and 0.3 s a word for a sentence;
  entrances 0.3–0.6 s.
- **Grounding:** every claim on screen is true of the product; the framing can play.
- **Transitions:** cross-fade, hard cut, flash cut, zoom cut (1.2 → 1.0), slide
  (0.35–0.45 s).
- **Sound with motion:** a sound starts with its motion; big reveals land on a strong beat
  of the music (±0.15 s), small entrances on a beat (±0.10 s).
- **Poster:** the best settled frame is baked in as frame 0, so every platform's preview
  shows it.

We do not take brag's method of an agent writing new HTML each time. YamVideo's graphics
are fixed templates with typed fields (graphics-track.md section 2), so a template runs the
same way every time and the owner can edit it.

## 4. Part A: YouTube numbers from a link

Fits distribution phase 4 (Results). The owner pastes a post's link in the Library today;
this reads its numbers.

1. **Check Numbers** on a YouTube post (a video or a Short) in the Library runs
   `yt-dlp --dump-json --skip-download URL` on this Mac, never with cookies. It stores a
   check-in: the date, the days since posting, views, likes and the comment count.
2. **New comments:** the newest comments (`--write-comments`, newest first, a capped
   number), with the ones not seen at the last check marked new.
3. **Day 1, 7 and 30:** the check-ins the owner compares (distribution decisions). The
   calendar's reminders can ask for them; nothing runs on its own.
4. **Agents:** a `checkPost` request (or Library command) that does the same and returns the
   numbers and the new comments; the results in the Library state.
5. **Tests:** parse a saved yt-dlp JSON file (no network in the suite); the refusals for a
   non-YouTube link.

Needs: `yt-dlp` on the Mac (Homebrew; a download, so ask the owner first) and a JavaScript
runtime for YouTube's player (Node is at `/usr/local/bin/node`; check whether yt-dlp takes
it or wants Deno). A free YouTube Data API key is the fallback if yt-dlp breaks: no
sign-in to the channel, but a Google Cloud key.

## 5. Part B: templates to click and run

A **Templates** gallery in the Studio: each template is a card. Click it, fill in its form
(the app name, screenshots, a few lines), see a preview, and run it. An agent can fill the
form from the project, its notes or the app's code, and the owner checks it before it
runs. Every template has agent commands and shows in the agent state.

### B1. App demo (a graphic)

A new graphics kind, `appDemo`: a phone frame with the owner's real app screenshots and a
list of steps the template plays in order: **tap** (a point, with a ripple), **type**
(text, a letter at a time), **swipe**, **toast** (a message), **next screen**, **count**
(a number counting up). It goes over the talking head, beside the speaker, like
`phoneScreens`, and it is the main scene of the launch Short (B2). The start of it exists:
`phoneScreens`, the typed URL in `link` and the count-up in `featureList`.

### B2. Launch Short (a generated video)

A 15–25 s vertical video with no camera, built from the brag shape in section 3: a hook,
the reveal (the app's name and promise), two or three highlights (each an app demo), and a
punchline with where to get the app. The form: the app's name, its one-line promise, the
highlights (screenshots, a line and the steps for each), the ending line and a tone. Run
renders it with HyperFrames to an MP4 in the video folder's `Files/` and adds it to the
project as a recording, so it can be cut, given music and exported as a Short like
anything else. The poster frame is baked in as frame 0.

### B3. Sound effects

Sounds tied to the templates' motion: a click on a tap, a key sound on each typed letter, a
soft sound when a card arrives. The CC0 packs from Kenney, with their credit file. They are
a native sound track mixed in the preview and the export, like the music bed
(background-music.md), with an on/off and a level for each template. Not brag's music:
its licence is unknown.

## 6. Order

| Step | What | Status |
|---|---|---|
| A | YouTube numbers from a link | Next. Ask the owner first to install yt-dlp |
| B1 | Templates gallery and the App demo template | After A |
| B2 | Launch Short template | After B1 |
| B3 | Sound effects | After B2 |

**Why this order:** the owner will give links as videos go out, so A is useful first. B2
is mostly B1's scenes in a row, and B3 gives sound to what B1 and B2 move.

## 7. Questions for the start of each step

The owner likes them asked one at a time, and mock-ups on their own footage before a look
is chosen.

- **A:** How many of the newest comments to keep at each check? Should a check run from
  the Library only, or from the calendar's reminders too?
- **B1:** Where the gallery lives: a Templates tab beside Media and Graphics, or the
  Graphics tab. Which app's screens to use for the first mock-up (the bike ride app?).
- **B2:** The tones to offer at first (brag has seven). The ending: a store badge, a link
  or a line.
- **B3:** Which sounds, at what level under the voice.

## 8. Sources

- Agent-Reach at its 2026-10-07 commit: `docs/install.md`, `agent_reach/skill/references/`
  (video, social, career), `agent_reach/integrations/mcp_server.py`, issues #802, #821.
- brag at its 2026-10-13 commit (v0.4.0): `README.md`, `skills/brag/SKILL.md`,
  `references/` (step-2-plan, step-3-compose, step-4-deliver, tones, audio), issues #35, #59.
