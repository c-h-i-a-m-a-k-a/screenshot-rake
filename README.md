# Day 01: Screenshot Rake

Custodian Cashew, a squirrel with a rake, walks onto your desktop, rakes up stray screenshots 3–5 at a time, and hauls each batch into a **Leaf Pile** folder. The folder is created if it doesn't exist and gets a leaf-pile icon. The files really move.

macOS only. Needs the Xcode command line tools (`swiftc`).

The squirrel is drawn from `art/sprite-sheet.png`, which is cut into the frames in `art/frames/` (walk, rake, carry, idle and cheer). Keep `art/` next to the `rake` script.

## Run

```bash
./rake
```

The first run compiles the app. macOS may ask to let your terminal control Finder. Allow it, because that's how the squirrel finds each icon on the desktop.

Cashew rakes once right away, then stays in the menu bar.

## Menu bar

| Item | What it does |
|------|--------------|
| **Send Custodian Cashew Now** | Rake right now |
| **Batch Size** | Which screenshots get raked each time: *Randomly a few* (3–5), *Oldest 10*, or *All* |
| **Repeat** | Rake on a schedule: *Off*, *Every 6 hours*, *Every 12 hours*, *Every day*, *Every week* |
| **Open Leaf Pile** | Open the folder in Finder |
| **Clear Leaf Pile…** | Move everything in Leaf Pile to the Trash (asks first) |
| **Quit Screenshot Rake** | Quit. Repeats only run while the app is open. |

Batch size and repeat are remembered between launches.

## Options

| Flag | What it does |
|------|--------------|
| `--dir PATH` | Rake a different folder (default `~/Desktop`) |
| `--speed X` | Speed up or slow down the animation (default `1`) |
| `--limit N` | Rake at most N screenshots |
| `--once` | Rake once and quit instead of staying in the menu bar |
| `--dry-run` | Play the animation without moving any files |
| `--mess N` | Create N fake screenshots and scatter them on the desktop |
| `--unrake` | Move everything out of Leaf Pile and scatter it back on the desktop |

## Recording takes

```bash
./rake --mess 12     # make a mess
./rake --once        # Cashew cleans it up
./rake --unrake      # put it all back for another take
```
