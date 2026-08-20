# Snippr

A screenshot tool shipped as two native builds from one repo: macOS in Swift
under `Sources/`, Windows in C#/WinForms under `windows/`. They are separate
implementations that agree on behaviour, not shared code.

## Before changing anything under `windows/`

Read **[docs/windows-performance.md](docs/windows-performance.md)**.

The Windows build is a tray utility that allocates bitmaps the size of the
whole virtual desktop and paints them at mouse-move rate. That doc lists the
rules that keep it from eating the machine, what each one protects, and which
gate notices when it breaks. Several of them look like things worth
"simplifying" and are not — the reasons are written down so you do not have to
rediscover them the way they were discovered.

The short version:

- Never `DoubleBuffered`/`OptimizedDoubleBuffer` on a desktop-sized surface —
  use `Ui/PaintBuffer.cs`.
- Never `Invalidate(true)` on `AreaReviewForm` — repaint the toolbar, with a
  rectangle where you can.
- Chrome colours come from `Ui/OverlayChrome.cs`. Never leave a control's
  background to WinForms: it answers `SystemColors.Control`.
- No `Pen`/`Brush`/`Region`/`Font` built inside a paint.
- Nothing that hashes, decodes or measures inside a paint.
- `Diag.Click` logs changes, not frames.

## Gates

Behaviour is pinned by three gates and a headless smoke, not by review:

| | Where | Runs on |
|---|---|---|
| ParityGate | `windows/Snippr.Win.ParityGate` | anywhere (`-f net8.0`) |
| RasterGate | `windows/Snippr.Win.RasterGate` | Windows only (GDI+) |
| StitcherGate | `windows/Snippr.Win.StitcherGate` | Windows only |
| `--test-shot` smoke | `windows/TestEntry.cs` | Windows only |

`.github/workflows/windows-ci.yml` runs all of them on `windows-latest` on
every push to a `claude/**`, `feat/**` or `fix/**` branch, and prints the
smoke's click log into the job. `windows/check-all.sh` is the local
equivalent; warnings fail in both.

Add a gate with the change, not after it. A gate that restates the code it
checks agrees with any bug — pin against an oracle, a literal, or pixels.

## Releasing

See [docs/RELEASING.md](docs/RELEASING.md). Windows needs the version bumped
in **three** places (`windows/Snippr.Win.csproj`, and `OutFile` +
`DisplayVersion` in `windows/installer.nsi`), a GitHub Release created
**before** the workflow runs — `.github/workflows/windows-installer.yml` only
uploads to an existing one — and `site/version.json` updated afterwards with
the installer's SHA-256.

`site/` deploys to Cloudflare Pages by **direct upload**
(`npx wrangler pages deploy site --project-name=snippr`), not from git. The
DMGs it links are gitignored, so deploying from a fresh clone removes them
from the live site. Check `ls site/*.dmg` first.
