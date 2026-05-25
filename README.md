# Shattlecoach 🏸

On-device form-coaching app for beginner badminton players — SNU Mobile Computing and Its Applications (4190.406B), Spring 2026 mini-project.

## Monorepo layout

```
shattlecoach/
├── frontend/        # Flutter app (iOS + Android). Owner: Eunwoo Choi.
│   ├── lib/
│   │   ├── features/        # ai_coach · report · sessions · equipment · settings · onboarding · shell · auth
│   │   ├── theme/           # app_theme.dart — single source of truth for colors
│   │   ├── routing/         # go_router config (onboarding gate + 5-tab shell)
│   │   ├── services/        # supabase_service.dart · auth_service.dart · onboarding_service.dart
│   │   ├── app.dart
│   │   └── main.dart
│   ├── assets/
│   │   ├── images/          # logo + onboarding illustrations
│   │   └── icons/           # custom monochrome icons (if not using Material)
│   ├── .env.example         # copy → .env and fill in keys
│   └── pubspec.yaml
├── inference/       # ML / on-device optimization. Owner: Donghwi Moon.
└── README.md        # this file
```

## Stack

- **Flutter** 3.44 · Dart 3.12 (channel stable)
- **Bundle ID:** `com.mca.shattlecoach`
- **State:** Riverpod
- **Routing:** go_router (ShellRoute for the 5-tab nav)
- **Backend:** Supabase (Postgres + Auth)
- **Auth:** Google social sign-in only
- **Permissions:** camera + notifications (asked behind primer screens in onboarding)

## Getting started

```bash
cd frontend
cp .env.example .env          # fill in SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_*_CLIENT_ID
flutter pub get
flutter run                   # pick an iOS simulator or Android emulator
```

The app boots without a configured `.env` — sign-in just fails with a clear message until keys are filled in.

## App structure

**Onboarding (4 steps):** Welcome carousel → Google sign-in → Profile setup (name, role, dominant hand, experience) → Permission primers (camera, notifications).

**Home (5-tab bottom nav):**

| Tab | Purpose |
|---|---|
| **AI Coach** | Stroke selection → 5-second swing capture → on-device scoring → radar chart + frame-level coaching |
| **Report** | Personal progress over time; weak-criterion heatmap |
| **운동 신청** | Browse, sign up for, and cancel club workout sessions (regular + ad-hoc) |
| **장비 공구** | Join shuttlecock / equipment group purchases — count + name only; payment off-app |
| **Settings** | Account, version info, dev tools (reset onboarding), sign out |

## Where to make design changes

- **Colors:** `frontend/lib/theme/app_theme.dart` (`AppPalette` + `_lightScheme` / `_darkScheme`).
- **Nav tabs / icons:** `frontend/lib/features/shell/home_shell.dart` (`_tabs`).
- **Onboarding copy:** `frontend/lib/features/onboarding/*.dart`.
