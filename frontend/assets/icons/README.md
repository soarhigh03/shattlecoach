# assets/icons

Custom monochrome icons (SVG converted to PNG, or 1-bit PNG) that don't ship with Material.

Suggested set for Shattlecoach:

- `shuttlecock.png` — could replace `Icons.sports_tennis` in the AI Coach nav tab.
- `racket.png` — possible alt for the AI Coach hero illustration.
- `court_topdown.png` — used by the camera-placement guide on the recording screen.

For multi-state tab icons keep `_filled` / `_outlined` variants. To use a custom asset as a nav icon, swap `Icon(...)` for `ImageIcon(AssetImage('assets/icons/...'))` in `lib/features/shell/home_shell.dart`.
