# assets/images

Place app-level image assets here:

- `logo.png` / `logo@2x.png` / `logo@3x.png` — the 셔틀코치 logo from the proposal cover (badminton court + 샤틀코치 wordmark).
- `onboarding_*.png` — onboarding illustrations (currently the Welcome screen uses Material icons; swap to PNGs when designed).
- `reference_swings/` — short MP4 / WebP-animation clips of senior-member reference swings (high_clear, low_clear, short_serve, forehand_drive). These are loaded by the AI Coach side-by-side comparison view.

Asset declarations are in `pubspec.yaml` under `flutter.assets`. Any new top-level folder needs to be re-declared there.
