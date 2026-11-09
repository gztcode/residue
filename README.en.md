# Residue

[![CI](https://github.com/gztcode/residue/actions/workflows/ci.yml/badge.svg)](https://github.com/gztcode/residue/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gztcode/residue?label=release)](https://github.com/gztcode/residue/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://github.com/gztcode/residue)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/github/license/gztcode/residue)](LICENSE)

[简体中文](README.md) · **English**

> See what the AI tooling on your Mac has been hoarding — then reclaim it **only after the app has proven its judgment**.

`uv`, `npm/npx`, and `pipx` quietly accumulate tens of gigabytes of cache. Residue does exactly three things:

| # | What it does | What it never does |
|---|---|---|
| 1 | **Read-only** reporting of how much each source occupies | No Full Disk Access, no reading file contents |
| 2 | A **14-day shadow observation period** that proves its judgment first | The observation period can't be skipped or shortened |
| 3 | On cleanup, only an **atomic rename into Trash** — one-click restore for 14 days | Never deletes directly, never overwrites |

> **It will not delete anything on its own.** You must switch auto-delete on yourself — and before that, it has to prove it judges accurately.

---

## Why it's trustworthy

Safety here isn't a promise; it's a structure a machine can re-check:

```
read-only scan ──→ 14-day shadow period ──→ gate evaluation ──→ you enable it ──→ rename to Trash
      │                    │                       │                                │
      │                    │                       └─ K ≥ H ∧ a = 0 ∧ b ≥ 1          └─ restorable within 14 days
      │                    └─ every round records "predicted reclaimable" vs "actually in use"
      └─ liveness via proc_pidinfo; file identity = (dev, ino), never the path
```

- **The only deletion primitive is `moveItem`.** There are no delete calls in `Sources/ResidueCore/TrashExecutor.swift` — verify with `grep`.
- **Unknown is never treated as safe.** Processes it can't see are honestly shown as "can't tell" — never 0, never a guess.
- **Upstream commands are a closed allowlist** of read-only lookups; every call is logged to `scan.jsonl`. Missing log = "unprovable".

---

## Requirements

| Item | Requirement |
|---|---|
| macOS | **14.0 or later** |
| CPU | **Apple Silicon only (arm64)** |
| Network | **Not needed at all** (zero outbound traffic) |

> **Why Apple Silicon only**: there is no Intel build in the first release. This isn't a "later" — **it won't run on an Intel Mac**. Open an issue if you need one; it will be considered.

---

## Install

1. Download the latest `Residue.app.dmg` from [Releases](../../releases)
2. Open the disk image and drag `Residue.app` into **Applications**
3. Eject the image, then open Residue from Applications

> ⚠️ **It must live in Applications.** Running it from the disk image, Downloads, or Desktop makes macOS place it in a random read-only path (App Translocation). The login item stops working and scheduled tasks won't run. The app detects this and warns you at the top of the window.

### First launch blocked by Gatekeeper?

Check which case the release notes describe:

#### Case A — release notes say "notarized"

Just open it. If it's still blocked, the download is incomplete — re-download and verify the SHA-256 below.

#### Case B — release notes say "not notarized / dev build"

Since macOS 15, un-notarized apps are refused. Allow it once:

1. Double-click `Residue.app`, then click "Done" on the warning
2. Open **System Settings → Privacy & Security** and scroll to **Security**
3. Click **"Open Anyway"** next to the Residue notice
4. Double-click `Residue.app` again and confirm "Open"

> One-time only. **Don't** run `sudo spctl --master-disable` — that disables Gatekeeper for the whole machine.

---

## Verify your download

Every release publishes a SHA-256. Compute it locally:

```bash
cd ~/Downloads
shasum -a 256 Residue.app.dmg
```

Compare character by character with the release notes. If they differ, don't open it — download again.

Then check the signature chain:

```bash
# Case A (notarized) should show: source=Notarized Developer ID
spctl --assess --type execute --verbose=4 /Applications/Residue.app

# Should pass in both cases (signature integrity)
codesign --verify --deep --strict --verbose=2 /Applications/Residue.app
```

> **Why this is so detailed**: there is no website — only this repository. These two commands are the only way to confirm the file you got is the one that was published. **That's the entire trust surface.**

---

## What it sees — and what it doesn't

<details open>
<summary><b>It reads</b></summary>

- Cache directories of `uv` / `npm` / `pipx`: path, item count, bytes, creation time
- **File-descriptor ownership** of same-uid processes (is this cache in use right now?)
- Output of **read-only lookup commands** (`uv cache dir`, etc.) to locate caches

</details>

<details open>
<summary><b>It never</b></summary>

| Never | Why |
|---|---|
| **Read file contents** | Only size and liveness matter; reading contents is neither necessary nor appropriate |
| **Scan personal files** | It works only under the cache roots you specify |
| **Request Full Disk Access** | It doesn't need it. Cross-uid processes are honestly reported as invisible |
| **Send anything out** | Zero telemetry, zero crash reports, zero update checks. Report export is a local file you trigger manually |

</details>

### What it writes

Two locations, both under `~/Library/Application Support/Residue/`:

- `state.residue` — observation progress, misjudgment records, bitmaps (**no filename lists**)
- `records/*.jsonl` — scan logs and execution records (source for exported reports)

**Cleanup only renames into Trash — it never deletes your files.**

> One exception, stated plainly: it removes **its own** temp files (`.tmp`), failed backups (`.bak`), and corrupt-state copies (`.corrupt`). Those are its own carriers, not your data.

---

## Uninstall

1. In Residue: **③ Cleanup policy → Scheduled task → turn off auto-delete**
2. **System Settings → General → Login Items** → remove Residue
3. Quit Residue (menu-bar icon → Quit)
4. Drag `/Applications/Residue.app` to Trash
5. Remove residual data:

```bash
rm -rf ~/Library/Application\ Support/Residue
```

> Step 5 permanently deletes observation progress and misjudgment records (`a`). Skip it if you're just reinstalling.
> Order matters: **turn off auto-delete → remove login item → delete the app**. Reversing it leaves an orphaned login item.

---

## Known limitations (no gloss)

| # | Limitation | Impact |
|---|---|---|
| 1 | **Apple Silicon only** | Won't run on Intel Macs |
| 2 | **Cross-uid fds are not enumerable** | Only your own user's processes are visible; others are shown as "can't tell" |
| 3 | **Incremental scans don't find deep new candidates** | Newly installed packages enter the list on the next full scan (daily by default) |
| 4 | **Three sources only** | `uv` / `npm(npx)` / `pipx` |
| 5 | **The observation period cannot be skipped** | 14 days is the core of the design, not an option |
| 6 | **A full scan itself takes ~10+ seconds** | ~12 s for ~220k items. Scans run on a background thread; the UI stays usable, shows live progress, and can be cancelled |
| 7 | **Un-notarized builds need a one-time manual approval** | See Case B above |

---

## Languages

The UI ships with **简体中文 / English**, follows the system language, and can be set per app in
**System Settings → General → Language & Region → Applications**.

> Contract documents under `docs/contract/` and release notes remain in Simplified Chinese — they are acceptance baselines, judged word by word.

---

## Engineering

```bash
cd ResidueApp
swift test                                  # 283 unit tests (Core, zero UI deps)
./scripts/verify_a9.sh                      # page structure + no-arithmetic-in-UI + wiring (72)
python3 scripts/verify_codes.py             # error-code table ↔ docs (11)
swift run --disable-sandbox ResidueApp --verify-wiring /tmp/w   # real IO round-trip (45)
./scripts/make_app.sh && ./scripts/verify_a5.sh                 # artifact structure (42)
```

Plus two document baselines: PRD 238 and R2 123 checks. CI re-runs everything on every build,
and asserts that **declared counts equal measured counts** — a mismatch fails the build.

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the repo layout and what this release explicitly
does *not* guarantee (not notarized, arm64 only, no GUI interaction verification).

One line worth knowing up front: **"CI green" is not "releasable."**

---

## Feedback

- **Bugs / feature requests**: [Issues](../../issues)
- An exported report shortens triage a lot: **⑦ Evidence & logs → Export redacted report**
  (Redacted: username → `<user>`, home → `<path>`, hostname → `<host>`; no file contents; exported manually, never uploaded)

> Check the "invoked / executed" columns for upstream commands in that report: **executed must be 0.**
> That's the app proving it never ran a command that deletes files.

---

## License

See [LICENSE](LICENSE).
