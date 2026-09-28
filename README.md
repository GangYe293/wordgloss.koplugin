# WordGloss

**Inline vocabulary glosses for English books in KOReader.**

WordGloss annotates difficult words with a short Chinese meaning printed directly above
(or below) the word — similar in effect to Amazon's Word Wise — **without modifying the
book by a single byte**. No `<ruby>` tags are injected, no XHTML is rewritten; the glosses
exist only inside the plugin's own cache and paint layer.

Current version: **1.8.1** (matches `_meta.lua`).

**[English](README.md) | [简体中文](README.zh-CN.md)**

![version](https://img.shields.io/badge/version-1.8.1-blue)
![platform](https://img.shields.io/badge/platform-KOReader-green)
![license](https://img.shields.io/badge/license-GPL--3.0-orange)

---

## Features

- **Non-destructive.** The EPUB archive, `.sdr` sidecar, bookmarks and reading progress are
  never touched. Clearing the plugin data restores everything exactly.
- **Opt-in, never automatic.** After installing, *nothing happens* when you open a book.
  You must tap **Start glossing** in the menu and choose a vocabulary size and translation
  scope — the network is only ever used at that moment.
- **Show / hide without losing anything.** `Show glossed words` is a separate control from
  `Start glossing`: hiding removes the glosses *and* the extra line spacing, but keeps every
  cached gloss — tick it again and everything is back instantly.
- **Vocabulary levels.** Beginner / Intermediate / Advanced decide *which* words are worth
  glossing, based on corpus frequency rank (Beginner = skip the most common 1,500 words,
  Intermediate 3,000, Advanced 5,000). A custom threshold is also available.
- **Offline local dictionary (default).** A trimmed ECDICT pack (~4 MB) ships inside the
  plugin: 41,145 headwords + 35,863 inflections, **92% with a part-of-speech tag**. It covers
  **100% of the plugin's own 39,301-word vocabulary list** (51% directly, 49% through the
  inflection table; 8 words fall through). Translating a whole book takes seconds and needs
  **no network at all** — switch to `Local only` and the plugin never makes a single request.
- **Glosses via the free Microsoft Edge endpoint** for whatever the dictionary lacks —
  coinages, names, places, brand-new slang. No API key required. Everything is cached in
  SQLite and reused across books, so each word is fetched once and page turns stay instant.
  `Gloss source` = `Local first` (default) / `Local only` / `Online only`.
- **Part of speech, when it exists.** The local dictionary carries `adj.` / `n.` / `vt.`; the
  online endpoint does not return it (verified: 0 of 22 sampled words). So `Show part of
  speech` (off by default) prints the tag **when there is one and leaves it out when there is
  not** — one page may mix both, which is intentional.
- **One-click part-of-speech backfill.** Cached glosses from older versions lost their tag
  during cleaning. `Clear gloss data → Backfill part of speech from the local dictionary`
  restores them offline, without touching the meanings themselves.
- **Manual and optional background translation.** Translate the current chapter or the whole
  book from the menu (runs in a child process, so you can keep reading and stop at any
  time). A separate "auto-translate while reading" toggle exists and is **off by default**.
- **Proper-noun filter.** Words that only ever appear capitalized (names, places) are skipped.
- **Adjustable gloss position.** `Small text above the word` / `Small text below the word`
  (order: word → underline → gloss). *Gloss offset* controls how far the gloss sits from the
  word (positive = push away, negative = pull closer); *underline offset* does the same for
  the underline. Line height grows automatically as offsets grow, so nothing collides with
  neighbouring lines.
- **Adjustable underline style.** Solid / dashed / wavy, thickness 1–6 px. Dashed and wavy
  share one *line density* control (smaller value = denser). Density offers small / medium /
  large presets plus **Custom** (2–24 px; for dashed = length of one dash segment, for wavy =
  half a wave). The wavy line uses the gentle custombg style: one full wave spans 12–22 px
  with an amplitude of only ~2 px, and it does **not** scale with line thickness, so thickening
  it never turns the line into a sawtooth.
- **Self-updating.** `About → Check for updates` asks GitHub Releases once (falling back to
  `gh-proxy` mirrors if GitHub is unreachable) and offers **code-only** (a few dozen KB) or
  the **full package** (with the offline dictionary). Downloads are **size-checked**, and
  **SHA-256 verified** when the digest is available, the
  previous version is **backed up** first, and you are asked whether to restart afterwards.
  Nothing is fetched unless you tap the item; a "check once a day" toggle exists (reminder
  only — it never installs on its own).
- **No mega-dictionary.** Two small packs ship inside the plugin: a 1.5 MB frequency pack
  (ranks + lemmatization) and the ~4 MB meaning pack above — both trimmed from ECDICT down to
  the words this plugin can actually annotate, not the several-hundred-MB dictionaries some
  other solutions require.

## Installation

1. Download `wordgloss-1.8.1.zip` (full package, includes the offline dictionary) or
   `wordgloss-1.8.1-code.zip` (code only — enough if the dictionary is already installed);
   both are attached to the release.
2. Extract / copy it into KOReader's `plugins/` directory. The final layout **must** be:

   ```
   <koreader>/plugins/wordgloss.koplugin/main.lua
   <koreader>/plugins/wordgloss.koplugin/_meta.lua
   <koreader>/plugins/wordgloss.koplugin/data/wordgloss_en.sqlite3
   <koreader>/plugins/wordgloss.koplugin/data/wordgloss_gloss_en.sqlite3
   ```

   The second file is the offline meaning pack. Without it the plugin still works — it just
   falls back to online translation for every word.

   By far the most common mistake is an **extra nested directory**
   (`plugins/wordgloss.koplugin/wordgloss.koplugin/main.lua`), in which case KOReader treats
   the plugin as non-existent.
3. **Fully quit and restart KOReader** — not just returning to the file browser; the process
   must actually exit.
4. Open an EPUB → top menu → **Tools** tab → **WordGloss**.

| Platform | `plugins/` location |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Android | `/storage/emulated/0/koreader/plugins/` |
| Linux / macOS / Windows | `koreader/plugins/` inside the KOReader directory |

### The plugin doesn't show up in the menu

KOReader wraps plugin instantiation in `pcall`: any exception thrown in `init()` produces no
dialog, only a single log line, and the plugin **silently disappears**. Check in order:

1. Directory layout as above (no extra nesting).
2. Open `koreader/crash.log` and search for `wordgloss`:
   - `Failed to initialize wordgloss plugin: ...` → the raw error thrown by `init()`;
   - `Error when loading .../wordgloss.koplugin/main.lua` → `main.lua` never loaded at all.
3. Did you restart the KOReader process completely? (Returning to the file browser doesn't count.)

> Version 1.0.0 hit exactly this: a loop variable named `_` shadowed the gettext function
> during menu construction, `init()` threw, and nothing appeared in the menu. Fixed in 1.0.1,
> which also added a fallback menu entry — if menu building fails, **Tools** still shows an
> entry that displays the reason.

## Usage

Menu: **top bar → Tools tab → WordGloss**. The plugin is **off** by default; it never does
anything on book open — you switch it on manually, once:

1. **Vocabulary size** — pick the ruler first: Beginner (skip the 1,500 most common words) /
   Intermediate (3,000) / Advanced (5,000), or a custom threshold.
2. **Start glossing** — open it and tap the **Start glossing** switch inside. That is what runs
   the conversion; afterwards you're asked for a translation scope: `Translate this chapter` /
   `Translate whole book (background)` / `Use cached glosses only` / `Cancel`.
3. **Show glossed words** (same submenu) decides whether the result is visible. Unticking it
   only *hides* the glosses — the extra line spacing is withdrawn too, but no data is deleted,
   so ticking it again restores everything.
   The gloss cache is **shared across books**, so it does not gate on the "Start glossing"
   switch: if any gloss was already translated (yesterday, or in another book), ticking
   **Show glossed words** displays it right away — no need to start the conversion again.
   Only when the cache is completely empty does it ask you to start one first.

Top level has just seven entries; every option lives inside one of them:

| Menu item | Description |
| --- | --- |
| **Start glossing** | Parent group. Contains: the **Start glossing / Stop glossing** switch (checked = conversion is active) and **Show glossed words** (show / hide the result). |
| **Vocabulary size** | Beginner 1,500 / Intermediate 3,000 / Advanced 5,000, or a custom threshold. |
| **Gloss settings** | Everything about the gloss text. |
| **Underline settings** | Everything about the line under the word. |
| **Translate settings** | **Network settings** (pick the online engine and its key), then **Gloss source** (`Local first` / `Local only` / `Online only`), then translate current chapter / translate whole book (re-translate all) / show progress / stop, plus the "auto-translate while reading" toggle (off by default). |
| **Clear gloss data** | Maintenance: `Clear this book's gloss data` / `Clear all cached glosses` / **`Backfill part of speech from the local dictionary`** (offline). |
| **About** | Version, author, Xiaohongshu ID, `Check for updates` (below), and the daily auto-check toggle. |

### Updating the plugin

`About → Check for updates` does the following (read-only until you confirm):

1. Asks GitHub Releases once, falling back to `gh-proxy` mirrors when GitHub is unreachable.
2. Shows the new version and its release notes, and lets you pick:
   - **Code only** (a few dozen KB) — use this when the offline dictionary is already there;
   - **Full package** (with the dictionary, ~3 MB) — when the dictionary is missing or you
     want a fresh copy.
3. Checks the byte size against the one the Release API reported (catches truncated downloads
   and proxy error pages), then compares the **SHA-256** digest *if* the `.sha256` file can be
   fetched — a mirror that never synced it is not allowed to block the update.
4. Renames the old directory to `wordgloss.koplugin.backup` and renames the new one into place
   — **if that rename fails it is immediately reverted**. The backup is kept until the new
   version has *successfully started once*, so if it cannot even load, renaming
   `wordgloss.koplugin.backup` back is a complete restore.
5. Asks whether to restart KOReader (until you do, the old version keeps running).

"Check once a day" is off by default. When enabled it asks once per day in the background and
**only shows a reminder** — it never downloads on its own, so reading is never interrupted.

*Gloss settings* → style, font size, per-page limit and font:

| Item | Description |
| --- | --- |
| Gloss style | `Small text above the word` (default) or `Small text below the word` (word → underline → gloss). |
| Gloss font size | 8–24 px. |
| Max glosses per page | When a page has too many hard words, the rarest ones win; `0` = unlimited. |
| Max gloss length | Truncation limit in characters, so a gloss always fits between two lines. |
| Show part of speech | Off by default. Prepends `adj.` / `n.` / `vt.` when the gloss has one. Only the **local dictionary** carries part of speech — the online endpoint does not return it — so a page will mix glosses with and without a tag: **shown when available, left empty when not**. |
| Gloss offset | Distance from word to gloss, −20…40 px. Positive = away from the word (upwards in "above" mode, downwards in "below" mode); negative = hugging it. |
| Gloss font | Default `Follow KOReader` uses KOReader's own CJK font; **Choose font…** opens KOReader's file browser so you can pick a `.ttf` / `.otf` / `.ttc` file yourself (long-press a file name to confirm). Pick a font with Chinese glyphs — otherwise every character renders as a tofu box. |
| Skip people / places | On by default; words that only ever appear capitalized are ignored. |

*Underline settings* → whether to draw it, what it looks like, and where it sits:

| Item | Description |
| --- | --- |
| Show underline | Toggles the line itself. A gloss is often wider than its word, so the line tells you which word it belongs to. |
| Underline style | Solid / dashed / wavy, plus **thickness** 1–6 px and **line density** (see below). |
| Line density | Dashed and wavy only: small (sparse) / medium / large (dense) / **Custom** (2–24 px, smaller = denser). |
| Underline offset | Distance from word to underline, −20…40 px. Positive = further below the word; negative = up against it. |

`Translate this chapter / Translate whole book` pops up a collapsible progress bar (tap outside
the window to collapse it and keep reading). The window contains only a title and the bar, and
it repaints at most once per 2% of progress instead of flickering twice a second. Once
translation finishes, turn the page to see the glosses. Words without a gloss simply aren't
displayed — reading is never blocked.

Both gloss modes inject a `line-height` to make room between lines, so the book is re-rendered
once when you start or stop — that space is what the glosses are painted into; the glosses
themselves don't consume body text area. In `Small text above the word` mode, line height is
the **larger** of (gloss height + gloss offset) and (underline offset + line height); in
`Small text below the word` mode both sit on the same side, so they are **summed** (clamped to
1.5–4.0). Larger offsets, thicker lines and the wavy style therefore all grow line height
automatically and never get clipped by adjacent lines.

## Where data is stored

| Data | Location |
| --- | --- |
| Language pack (frequency ranks + lemmatization) | `plugins/wordgloss.koplugin/data/wordgloss_en.sqlite3` |
| Gloss cache / per-book state | `wordgloss.sqlite3` (WAL) in the KOReader data directory |
| Prefetch progress and cancel flags | `cache/wordgloss/` in the KOReader data directory |
| Update staging directory | `wordgloss-update/` in the KOReader data directory (deleted when done; never inside the plugin) |
| Backup of the previous version | `plugins/wordgloss.koplugin.backup/` (removed after the new version starts successfully) |
| Settings | KOReader's native `settings.reader.lua` (`wordgloss_` prefix) |

## How it works

1. **Deciding which words are hard.**
   The pack `data/wordgloss_en.sqlite3` has a single table `lex(word, rank, base)`:
   `rank` is the corpus frequency rank (1 = *the*), `base` is the lemma of an inflected form
   (`took` → `take`). The rule: normalize the token (strip punctuation, stem apostrophes,
   ignore contraction stems like `don't`), look up the lemma's rank — a rank within the
   threshold counts as "known" and is skipped; above the threshold, or absent from the pack,
   it's a hard word. Words missing from the pack also fall back to suffix rules
   (`stopped` → `stop`), and the fallback is only accepted if the result is genuinely common.

2. **Fetching glosses.**
   `wordgloss_providers.lua` calls the free Edge endpoint (batches of ≤ 12 items / ≤ 4000 bytes,
   degrading to one-by-one if a batch fails). It translates the **lemma**, so `took` / `taken` /
   `takes` share a single gloss. Results are trimmed by `wordgloss_gloss.lua` (first line only,
   stray part-of-speech prefixes and parenthetical extras removed, truncated by character count,
   leading/trailing punctuation stripped) and written to the cache; **a failed translation also
   stores an empty record** so the same word isn't retried forever.

3. **Prefetching.**
   `wordgloss_epub.lua` unpacks the EPUB, locates chapters via the spine, and collects each
   chapter's words with a paragraph-level scan (independent of rendering).
   `wordgloss_prefetch.lua` translates chapter by chapter **in a child process** and writes
   results into the cache. Progress comes back through a progress file and cancellation through
   a sentinel file, so whole-book translation never blocks the reading UI.

4. **Display.**
   `wordgloss_page.lua` walks word by word using CREngine's `getPageXPointer` /
   `getNextVisibleWordStart|End` / `getTextFromXPointers`, and takes screen coordinates from
   `getScreenBoxesFromPositions`. `wordgloss_overlay.lua` registers itself as a ReaderView view
   module and paints the gloss above the word (`Small text above the word`) or below the
   underline (`Small text below the word`). When a line can't fit everything, the most common
   words are dropped and the rarest kept; inter-line space comes from the injected
   `line-height`.

## Building the language pack

The pack is generated by `tools/build_en_db.py` from ECDICT's `test.db` (frequency field `frq`)
and Stardict's `lemma.en.txt` (lemmatization):

```sh
python tools/build_en_db.py --dict test.db --lemma lemma.en.txt \
    --out data/wordgloss_en.sqlite3 --max-rank 20000
python tools/check_pack.py     # spot-check ranks and lemmas to validate the pack
```

- Words ranked ≤ 20000 go into the pack; everything else (including words absent from the pack)
  is treated as out-of-vocabulary.
- Licensing: WordGloss itself is GPL-3.0; the data pack inherits its sources' licenses
  (ECDICT MIT, Stacheldict `lemma.en.txt`) — see the notes in `data/` and `tools/`.

## Cutting a release

`tools/release.py` does packaging and publishing in one go (no `gh` CLI needed — it talks to
the GitHub API directly):

```sh
python tools/release.py                  # checks + packaging + prints the remote commands
python tools/release.py --execute        # also tags, pushes, creates the release and uploads
```

The version is read from `_meta.lua` (and cross-checked against `VERSION` in `main.lua`).
Four files land in the parent directory of the repository:

| File | Contents |
| --- | --- |
| `wordgloss-<version>.zip` | Full package: code + the `data/` dictionary (~3 MB) |
| `wordgloss-<version>-code.zip` | Code only, no `data/` (~100 KB) |
| both `.zip.sha256` | Their SHA-256, verified before installing when available |

Both zips have `wordgloss.koplugin/` as their top-level directory, so extracting into
`plugins/` gives the correct layout (that is also what the self-updater expects).
`--execute` needs a GitHub token:

1. https://github.com/settings/tokens → **Generate new token (classic)**
2. Tick `public_repo`
3. `set GITHUB_TOKEN=ghp_xxx` (PowerShell: `$env:GITHUB_TOKEN="ghp_xxx"`), or pass
   `python tools/release.py --execute --token ghp_xxx`

Before publishing it checks that the working tree is clean, you are on `main`, nothing is
unpushed, and the tag does not already exist remotely.

## Tests

The pure-Lua logic (hard-word detection, gloss trimming, gloss layout, paint layer,
line-height injection, menu) runs offline — no KOReader and no Lua install needed, using
fengari (a Lua VM in JavaScript):

Tests live in **`tests/wordgloss/` at the workspace root** (not inside the plugin directory —
that directory is treated as "runtime files only" and gets cleaned, so tests placed there keep
disappearing). Stubs live in `tests/wordgloss/stubs/`.

```sh
# fengari runner (Lua VM inside Node)
NODE=node                                   # or your node binary
RUNNER=/path/to/luatest/runlua.js
T=/absolute/path/to/tests/wordgloss         # both arguments must be absolute paths
"$NODE" "$RUNNER" "$T" "$T/run_tests.lua"   # pure logic + paint layer + menu + offline dict + updater: 222 assertions
"$NODE" "$RUNNER" "$T" "$T/run_load_test.lua"   # can all 16 modules be loaded
"$NODE" "$RUNNER" "$T" "$T/dump_menu.lua"       # print the real menu tree and labels
```

The scripts derive the workspace root from `arg[0]` and then assemble the plugin path, so they
run on any machine with the same directory layout.

`tests/run_load_test.lua` reproduces KOReader's real plugin-loading sequence
(`dofile(main.lua)` → `pcall(plugin.new, ...)` → `registerToMainMenu`) and actually invokes
every `text_func` / `checked_func` in the menu — it is what caught the "plugin invisible in the
menu" bug, and it also guards 1.1.0's "never auto-run" rule (while disabled, no gloss may be
painted and no translation may be requested). Run both suites after editing `main.lua` or
`wordgloss_ui.lua`.

`tests/dump_menu.lua` prints the real menu tree, useful for checking entry labels and order:

```sh
node runlua.js <tests/wordgloss> <tests/wordgloss>/dump_menu.lua
```

`tests/wordgloss/stubs/` holds minimal stubs of KOReader modules (generated by
`make_stubs.py`); the test scripts add them to `package.path` themselves.

## Changelog

- **1.8.1** — **More robust online translation.** ① Weak-network retries: connection
  failures, DNS errors, timeouts and 5xx responses are retried twice with 2 s / 3 s
  backoff. Errors that will never succeed on a retry (401 bad key, 429 rate limited,
  456 quota exhausted) are returned immediately. Each request is capped at 90 s in total,
  so prefetching a whole book cannot stall. ② Human-readable errors: 401 → "the API key is
  invalid or expired", 403 → "no access", 429 → "rate limited, try again later",
  456 → "quota exhausted", 5xx → "service temporarily unavailable". ③ Fixes a
  long-standing mistake: with luasocket, `http.request{…}` returns "did it connect" as its
  *first* value, not the status code. It was never skipped, so the real status code and
  error message were always read from the wrong slot — that is where the
  `HTTP error: nil nil` log lines came from. Network failures and HTTP errors are now
  handled separately, and the log shows the real status code.
- **1.8.0** — **the online engine is now selectable.** The translate menu gained a
  `Network settings` entry: Microsoft Edge stays the default (free, no key), and you can
  switch to Zhipu GLM-4 Flash or SiliconFlow (free tier), or to DeepL, DeepSeek and any
  OpenAI-compatible endpoint (paid, key required). The layout follows
  ai_translator.koplugin: the current engine on top, then **Free** / **Paid** groups with
  each engine's settings underneath. DeepL's "translate from / translate to" pickers are
  gone — a gloss can only be English → Chinese, so the target is fixed. Keys are read from
  the plugin's own settings first and fall back to the same key stored globally by the AI
  translator plugin, so an existing key does not have to be entered twice. Models are
  requested in batches of 20 words (25 for DeepL) and asked to reply with a JSON array;
  unparsable batches fall back to per-word retries, and the timeout was raised to 45 s.
  Translation still runs in a subprocess, so page turns are unaffected. This release also
  fixes an old bug: when one word failed to translate, every later word's gloss shifted
  up by one position.
- **1.7.0** — **Menu and message cleanup.** Removed every "Note: …" line from the UI
  (start glossing, gloss style, gloss font, line density, part of speech, translate menu,
  update dialog — 7 in total), so menus list options only. In `About`, version and author
  are no longer greyed out, the GitHub URL is gone, and a Xiaohongshu ID line was added;
  the `Status:` line at the bottom of the main menu was dropped (8 → 7 top-level entries).
  Renamed: `Translate words (online)` → **Translate settings**, the vocabulary
  `Custom threshold` → **Custom**, and the daily update check lost its "(reminder only,
  never installs)" suffix. **Editing a setting no longer drops you back to the reader**:
  gloss font size, per-page limit, gloss length limit, gloss offset, underline offset,
  underline thickness and the font picker all keep the menu open and refresh their own
  label (the custom threshold and custom density pickers do too). Action items
  (translate, clear, check for updates) still close the menu as before. **Network
  failures are now reported in Chinese**: DNS, timeout and refused-connection errors no
  longer leak raw English strings such as `temporary failure in name resolution` — they
  show a single "网络连接失败，请检查网络" message. Real HTTP status codes are still
  shown as-is (for example "下载失败（HTTP 500）").
- **1.6.0** — **the plugin can update itself.** New `About` menu: shows the version and the
  author, and `Check for updates` asks GitHub Releases once (falling back to `gh-proxy` mirrors
  when GitHub is unreachable), offering **code only** or the **full package** (with the offline
  dictionary). The flow is **download → size check → SHA-256 when available → extract outside
  the plugin directory → rename the old version to a backup → rename the new one into place**;
  a failed rename is
  reverted immediately, and the backup survives until the new version has started successfully
  once (so renaming `wordgloss.koplugin.backup` back restores everything). You are then asked
  whether to restart KOReader. "Check once a day" is off by default and only ever reminds you —
  it never installs by itself. The updater (`wordgloss_update.lua`) and its bundled SHA-256
  implementation (`wordgloss_sha2.lua`) need no third-party code, only KOReader's own
  `socket.http` / `json` / `ffi-archiver`. Releases are cut with `tools/release.py`
  (package + tag + release in one command). The top-level menu entry is now **`WordGloss`**
  (was "生词注释"); the plugin's full name is `WordGloss（生词注释）`.
- **1.5.0** — **offline local dictionary, online becomes the fallback.** A trimmed ECDICT pack
  (`data/wordgloss_gloss_en.sqlite3`, ~4 MB) now ships with the plugin: 41,145 headwords plus
  35,863 inflections, 92% carrying a part-of-speech tag. Prefetch looks words up locally first
  and only sends the leftovers to the Edge endpoint, so a whole book is glossed in seconds and
  **`Local only` translates a book with zero network requests**. New `Gloss source` menu
  (`Local first` / `Local only` / `Online only`).
  **Part of speech is back** as an opt-in `Show part of speech` (off by default): the local
  dictionary provides `adj.` / `n.` / `vt.`, the online endpoint does not (verified 0/22), so
  the rule is *show it when there is one, leave it out when there is not*.
  `Clear gloss data` gained **Backfill part of speech from the local dictionary**, which fills
  in the missing tags of already-cached glosses offline. Local meanings are truncated with the
  same `Max gloss length` / item limits as online ones, so both sources look identical.
  Regenerate the pack any time with `tools/build_gloss_db.py`.
- **1.4.1** — fixed **"Start glossing first" showing up even though the book was already
  translated**. Root cause: KOReader's `LuaSettings:saveSetting` only touches memory, and only
  `flush()` writes `settings.reader.lua`; since KOReader flushes on clean exit only, a suspended
  / power-cut Kindle session silently lost the `enabled` state — while the SQLite gloss cache
  survived, which is why "the data is there but the switch is gone". Settings are now flushed
  immediately after every change. Second, **Show glossed words** no longer gates on the start
  switch but on whether the (cross-book, shared) gloss cache actually has entries, so anything
  you glossed before can be shown again directly; the start switch is repaired in the process.
- **1.4.0** — **menu restructured** into seven top-level entries: `Start glossing`
  (containing the start/stop switch and the new **Show glossed words** checkbox),
  `Vocabulary size`, `Gloss settings`, `Underline settings`, `Translate words (online)`,
  `Clear gloss data` and `Status`.
  `Show glossed words` is now independent from `Start glossing`: hiding the glosses removes them
  *and* the extra line spacing, but keeps all data, so re-ticking restores everything (ticking it
  before any conversion simply reminds you to start one first).
  `Underline glossed words` renamed **`Show underline`** and moved together with `Underline
  style` and `Underline offset` into `Underline settings`. Gloss-side options moved into
  `Gloss settings`. The two offset items lost their `positive = away` suffix. The gloss font entry
  is now **`Choose font…`**, which opens KOReader's file browser for a `.ttf` / `.otf` / `.ttc`
  file instead of asking you to type a font name (falls back to typing if the file browser isn't
  available in that KOReader build).
- **1.3.0** — **redrawn wavy underline** (the old one had a 4–8 px wavelength with amplitude
  scaling with thickness, i.e. a sawtooth). Now uses custombg.koplugin's gentle style: one full
  wave spans 12–22 px with a fixed 1–2 px amplitude (driven by wavelength only, so thickening
  doesn't steepen it). **Line density gains a `Custom` option**: enter 2–24 px (dashed = length
  of one dash segment, wavy = half a wave); smaller = denser. The three presets map to 11 / 6 /
  3 px.
- **1.2.1** — fixed **missing underline on the second line of a hyphenated word**. When a word
  is split across two lines, CREngine returns multiple screen boxes; only the first was used,
  so the gloss rendered fine but the underline covered just the first half. Now every box gets
  its own line (dash/wave style, offset and thickness all apply per box); the gloss is still
  painted once.
- **1.2.0** — removed the "vocabulary list below paragraph" mode in favour of
  **`Small text below the word`** (order: word → underline → gloss);
  "Small text above the word (Word Wise style)" renamed to `Small text above the word`.
  Underlines gain a **wavy** style, and dashed/wavy both gain **line density**
  (small / medium / large, large = denser). Line-height calculation now splits per mode into
  "take the larger side" vs "sum both sides", and the wave's crest and trough count toward
  line height.
- **1.1.0** — switched to **manual start**. The plugin is off by default and no longer runs on
  book open; new first menu entry **Start glossing**, with vocabulary size moved to second.
  "Prefetch words" renamed to "Translate words (online)", plus a new, off-by-default
  "auto-translate while reading" toggle. Automatically triggered translation **no longer pops a
  progress window** (in 1.0.x it flashed by).
- **1.0.1** — fixed the `_`-shadowing bug in menu construction (the plugin used to vanish from
  the menu silently); added the fallback menu and the load test.
- **1.0.0** — first release.

## Known limitations

- **English only.** The frequency and lemma data is English, and tokenization splits on spaces.
- Glosses are machine translations and **do not disambiguate senses** (polysemous words get
  their most common meaning). They are hints, not a dictionary.
- The offline pack covers 77k word forms. Anything outside it (coinages, names, places, very
  new slang) still needs one online fetch the first time — and only if `Gloss source` is not
  `Local only`. Only the word itself is sent, never the surrounding text.
- Proper-noun filtering is a "only ever seen capitalized" heuristic; a rare word appearing just
  once at the start of a sentence may be missed.
- Both gloss modes change line height. If you care strongly about the book's original
  typography, shrink the gloss font and set offsets back to 0.

## Credits

- The inline-gloss rendering approach follows
  [omer-faruq/inlinehints.koplugin](https://github.com/omer-faruq/inlinehints.koplugin)
  (AGPL-3.0): painting glosses from a ReaderView view module and injecting line height to make
  room.
- EPUB parsing and the `::after` overlay injection follow
  [dualtranslate.koplugin](https://github.com/enneaa/dualtranslate.koplugin) (GPL-3.0); this
  project's `wordgloss_tools.lua` and paragraph-scanning logic are ported from it.
- Frequency, lemma and offline meaning data all come from
  [ECDICT](https://github.com/skywind3000/ECDICT) (MIT). `tools/build_en_db.py` and
  `tools/build_gloss_db.py` trim it down to the words this plugin can actually annotate;
  the 790 MB source database is **not** distributed.
- The vocabulary-tier idea (1,500 / 3,000 / 5,000) follows epub-rosetta's Word Wise
  implementation, minus its two drawbacks: rewriting and re-zipping the EPUB, and depending on
  a 790 MB local dictionary.

Word Wise is an Amazon trademark. This project is not affiliated with it; the similarity is
only in effect.

## License

GPL-3.0 (consistent with the projects it references and ports from).

---

**[English](README.md) | [简体中文](README.zh-CN.md)**
