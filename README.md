# Day 01: Screenshot Rake

Custodian Cashew, a squirrel with a rake, walks onto your desktop, rakes up stray screenshots 3–5 at a time, and hauls each batch into a **Leaf Pile** folder. The folder is created if it doesn't exist and gets a leaf-pile icon. The files really move.

macOS only. Building needs the Xcode command line tools (`swiftc`).

## Install

```bash
./build-app
```

This builds **Screenshot Rake.app** and puts it in your Applications folder. Open it like any other app (Launchpad, Spotlight, or double-click) and a settings window opens with a **Rake Now** button and every option. Closing the window keeps Cashew running for scheduled rakes; click the Dock icon to bring the window back.

The first time, macOS asks to let Screenshot Rake control Finder. Allow it, because that's how the squirrel finds each icon on the desktop.

To start it automatically, add it in **System Settings → General → Login Items**.

## Menu bar

The same controls are also under the squirrel icon in the menu bar, plus **Settings…** to open the window.

| Item | What it does |
|------|--------------|
| **Send Custodian Cashew Now** | Rake right now |
| **Batch Size** | Which screenshots get raked each time: *Randomly a few* (3–5), *Oldest 10*, or *All* |
| **Repeat** | Rake on a schedule: *Off*, *Every 6 hours*, *Every 12 hours*, *Every day*, *Every week* |
| **Open Leaf Pile** | Open the folder in Finder |
| **Clear Leaf Pile…** | Move everything in Leaf Pile to the Trash (asks first) |
| **Make a Mess** | Scatter 12 fake screenshots on the desktop for Cashew to rake |
| **Quit Screenshot Rake** | Quit. Repeats only run while the app is open. |

Batch size and repeat are remembered between launches.

## Options

The `rake` script runs the same app from the terminal, with extra options:

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
