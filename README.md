<p align="center">
  <img src="Resources/Branding/AppIcon.png" width="160" alt="MH Desk Pets — Mizutsune icon">
</p>

# MH Desk Pets

Monster Hunter desktop companions for Claude Code and Codex on macOS, built with Swift and AppKit.
Each pet follows a CLI session and animates when it is working, waiting for input, or idle.

![Monster companions grouped by state: Rathalos, Zinogre, Mizutsune, and Valstrax working; Tigrex and Velkhana waiting for input; Nargacuga and Nergigante idle](docs/assets/preview.gif)

Selected companions, grouped by state and ordered by EM ID within each group, at a 1.2-second loop.
Every monster has all three animations.
Browse the [full monster roster](docs/monsters.md) for previews and names in English, Traditional Chinese, and Japanese.
The roster and in-app character lists follow numeric EM ID order.

- English, Traditional Chinese, and Japanese UI and monster names
- Adjustable animation speed and size (64–256 px), saved automatically
- Drag pets anywhere; double-click to focus their terminal, including tmux panes and cmux tabs
- Optional translucent habitat with automatic rooms, drag-to-swap, and a handle to move pets together
- Import custom GIF characters or add monsters from PNG frames

## Build and install

Requires an Apple Silicon Mac, macOS 14+, Swift 6 (Command Line Tools), and FFmpeg.

```sh
git clone https://github.com/chesterXalan/mh-desk-pet.git
cd mh-desk-pet
brew install ffmpeg
make app
```

Copy `build/DeskPets.app` to `/Applications` and open it.
`make run` builds and opens the app; `make test` runs the tests.

## Use

1. Open **Manage… → Hooks** from the menu bar, install the hooks, and restart your CLI sessions.
2. Start Claude Code or Codex—a pet appears automatically. Choose its monster in **Sessions**.
3. Drag pets to place them; double-click to focus their terminal. Adjust language, size, and speed in **Settings**.
4. Optionally, enable **Habitat** to group pets into rooms; drag its handle to move them together.

Character choices and positions are remembered automatically.
See [Usage details](docs/usage.md) for habitat controls and terminal compatibility.

## Add characters

Use **Characters → Add Character…** to choose an idle GIF, with optional working and waiting animations.
Source filenames are unrestricted; the app copies and names the files automatically in the character's folder.
To add a built-in monster, see [Character assets](docs/characters.md).
PNG frames and character metadata are versioned; GIFs are generated during the build.
The app icon source and GitHub preview are versioned too; see [Branding](docs/branding.md).

## Development

Write code comments and documentation in English. Keep user-facing text localized in English,
Traditional Chinese, and Japanese. Write new commit messages in English using Gitmoji + Conventional
Commits, for example `✨ feat: Add a monster companion`.

Run `make test` and `make app` for code changes, and `make catalog` when changing character metadata.

## Local data

Settings, bindings, and imported characters live in `~/Library/Application Support/DeskPets/`.
Hook installation updates `~/.claude/settings.json` and `~/.codex/hooks.json`, preserving existing hooks
and backing up each file before changes. The app does not make network requests.

## Credits

Based on [youngOman/desk-pets](https://github.com/youngOman/desk-pets), inspired by our colleague Evan's agent-pets.
Code is licensed under [MIT](LICENSE), with the upstream copyright notice preserved.
Monster Hunter characters belong to CAPCOM; the included artwork is AI-generated fan art.
