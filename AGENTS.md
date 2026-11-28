# AnymeX — Agent Guide

> **How to add a feature.** You build the feature. No tests, no docs.

## What this is

AnymeX is a large multi-platform **Flutter** app (Android, iOS, Windows, Linux, macOS).
It's a *multiservice tracking client* for anime/manga/novels. It tracks progress on
three official services — **AniList**, **MyAnimeList**, **Simkl** — and integrates
community **extensions** (sources/repos) via a plugin bridge.

- Package name: `anymex`
- Flutter SDK managed by **fvm** (see `.fvmrc`) — run `fvm flutter run` etc.
- Build system: standard Flutter; platform folders under `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/`.
- Persistence: **Isar** (`isar_community`) for structured data + **Hive/KvHelper** for tiny key/value settings.
- State: **GetX** (`package:get/get.dart`) — controllers with `Rx`/`obs` reactive fields.
- HTTP: `rhttp` (local package `packages/rhttp`) + `dio` + `http`.
- Media playback: custom **MediaKit** fork (`media_kit`).
- Localization: Flutter `gen-l10n` ARB files under `lib/l10n/`, accessor `context.l10n` / `Get.context!.l10n`.

## First-time setup

```sh
fvm flutter pub get      # after changes to packages/
flutter run               # or a specific target: flutter run -d chrome
```

The app **won't build** without a `.env` file at the repo root. Stub it for local dev:

```env
AL_CLIENT_ID=0
AL_CLIENT_SECRET=0
SIMKL_CLIENT_ID=0
SIMKL_CLIENT_SECRET=0
MAL_CLIENT_ID=0
MAL_CLIENT_SECRET=0
CALLBACK_SCHEME=anymex://callback
COMMENTS_BASE_URL=https://whzwmfxngelicmjyxwmr.supabase.co/functions/v1
```

## Architecture map

```
lib/
├── main.dart                      # Entry. Boot sequence, GetX registration, app shell.
├── ai/                            # (presence/AI helpers)
├── constants/
├── controllers/                  # GetX controllers (state + business logic)
│   ├── cacher/                   # Image cache controller
│   ├── custom_logo/              # Logo animation config
│   ├── discord/                  # Discord RPC
│   ├── media_mode_controller.dart
│   ├── network/                  # network_manager, interceptors
│   ├── offline/                  # offline/local media storage
│   ├── service_handler/          # ServiceHandler (which service is "active")
│   ├── services/                 # Community add-on services (Torrent, Commentum, upscale, ...)
│   ├── settings/settings.dart    # Central Settings controller (feature flags live here)
│   ├── source/source_controller.dart  # Extension/source registry + home sections
│   ├── stats/                    # Stats tracking
│   ├── sync/                     # gist sync
│   ├── theme.dart                # ThemeController (light/dark/OLED, shaders)
│   ├── track/                    # Tracking binding (which list a media belongs to)
│   ├── ui/                       # GreetingController, etc.
│   ├── watchium/
├── core/metadata/
├── database/
│   ├── isar_models/              # Isar schema classes
│   ├── data_keys/keys.dart       # Named keys for KvHelper
│   └── kv_helper.dart
├── l10n/                          # ARBs + locale controller + context.l10n accessor
├── models/
│   ├── Media/media.dart          # Big Media model (the main content entity)
│   ├── Anilist/                  # AniList DTOs
│   ├── Service/                  # BaseService + OnlineService interfaces
│   ├── animethemes/, mangaupdates/, sauce/, reader/, player/
├── repositories/
├── screens/
│   ├── home_page.dart            # Main nav (Home/Discover/Search/Library/History/Stats/Anime/Manga/Novel/Extensions)
│   ├── anime/ (home, details, watch/*, widgets)
│   ├── manga/ (home, reading, widgets)
│   ├── novel/ (home, reader/*)
│   ├── library/ (my_library, history, stats, online/*, widgets, controller, editor)
│   ├── search/ (search_view.dart, source_search_page.dart)
│   ├── downloads/ (download_screen.dart, controller/, model/)
│   ├── settings/ (settings.dart, sub_settings/*, registry/settings_labels.dart)
│   ├── community/
│   ├── notifications/
│   ├── extensions/ (ExtensionScreen, ExtensionList, ExtensionItem, settings, testing)
│   ├── onboarding/, profile/, stats/, other_features.dart, watchium/
├── services/
│   ├── upscale/                  # AI/GPU upscaler (shaders)
│   ├── cast/
│   ├── fcm_service.dart          # Firebase messaging
│   ├── commentum_service.dart    # Comments/social
│   ├── anilist_notification_service.dart
│   └── volume_key_handler.dart
├── utils/                        # Helpers (function.dart is a big general util file,
│   ├── download_isolate_pool.dart, media_downloader.dart, media_syncer.dart,
│   ├── color_profiler.dart, liquid.dart, logger.dart, deeplink.dart, language.dart,
│   ├── online_subtitles.dart, subtitle_translator.dart, sub_parser.dart, ...
└── widgets/                      # Reusable UI (anymex_widgets/, common/, header/, non_widgets/)
```

## Core conventions (follow these)

1. **GetX controllers, not providers.** State lives in `GetXController`s registered in
   `main.dart` `_initializeGetxController()`. Access via `Get.find<X>()`, observe via
   `Obx(() => ...)`, navigate via `navigate(() => ...)` (from the `navigate` helper in
   `utils/function.dart`).
2. **Reactive fields.** Declare state as `final foo = 'x'.obs;` or `RxBool/Rxn/RxList`
   fields. `Settings` (`SettingsController`) and `ThemeController` are the global
   singletons most widgets reach for.
3. **Services = `BaseService` + `OnlineService`.** Each tracking service (AniList, MAL,
   Simkl) is a GetX controller implementing these two interfaces. They own:
   - `RxList<TrackedMedia> animeList/mangaList`, `Rx<TrackedMedia> currentMedia`,
     `isLoggedIn`, `profileData`.
   - `homeWidgets()` / `animeWidgets()` / `mangaWidgets()` / `novelWidgets()` —
     return `RxList<Widget>` sections rendered on the Home/Discover tabs.
   - `fetchDetails()`, `search()`, `updateListEntry()`, `deleteListEntry()`,
     `setCurrentMedia()`, login/logout/refresh.
   - `clearState()` / `isDataLoaded` / `fetchHomePage()`.
4. **`Media` is the central entity.** Content (anime/manga/novel) is a `Media` object
   with a `serviceType` (anilist/mal/simkl/extensions/offline) and `mediaType`
   (anime/manga/novel → `ItemType`).
5. **Extensions/sources are a plugin bridge** (`anymex_extension_runtime_bridge`, a git
   dep). The app talks to installed sources through `SourceController` /
   `ExtensionManager`. You generally do **not** edit the bridge from app code.
6. **Localization.** Add UI text by adding a key to `lib/l10n/app_en.arb` and using
   `context.l10n.<key>`. Outside widgets use `Get.context!.l10n.<key>`. Never localize
   dynamic content (titles, names, scraper output). For settings *category/section*
   labels, add an English string to the `SettingsRegistry` and a case to
   `screens/settings/registry/settings_labels.dart`.

## Feature-flagging convention

Most toggles live on the `Settings` controller as `RxBool`/`RxInt`/`RxString`. Add a
new feature by:
1. Adding the field (e.g. `RxBool enableFoo = false.obs;`) to `lib/controllers/settings/settings.dart`.
2. Adding a settings UI entry (see `lib/screens/settings/sub_settings/*.dart` for the
   pattern) and, if it's a category/section label, a case in
   `registry/settings_labels.dart`.

## Adding a feature (the workflow)

There is no test suite and no enforced conventions gate. Typical steps:

1. Decide the layer: **feature flag** → `Settings`; **data** → Isar model + `database/`;
   **business logic** → a GetX controller in `controllers/`; **UI** → `screens/` + `widgets/`.
2. If it's a content service like AniList/MAL/Simkl, implement `BaseService` +
   `OnlineService`, add API calls (often via `NetworkManager`), and register it in
   `main.dart`'s `_initializeGetxController()`.
3. If it's a Home/Discover section, return widgets from the relevant `*Widgets()` method
   of a service/controller and make sure it's composed into the section list.
4. Add any new strings to `app_en.arb`.
5. Build & run: `fvm flutter run`. Keep changes small and consistent with surrounding
   style (named constructors, `super.key`, `Rx` state, `context.colors` theming,
   `AnymeX`-prefixed custom widgets over raw Material where the codebase does it).

### Notes / gotchas
- The app requires `.env` or it won't build.
- `enableLog: true` + custom `Logger` — console is noisy; use `Logger` for diagnostics.
- Platform-specific boot branches in `main.dart` (`Platform.isWindows/Linux` register
  protocols; Firebase only on non-Android/iOS).
- Downloads use a Dart isolate pool (`utils/download_isolate_pool.dart`).
- Upscaling uses GPU shaders registered in `services/upscale/shader_registry.dart`.
- `settings_registry.dart` keeps plain-English IDs stable; `settings_labels.dart` maps
  them to localized strings (keep them in sync).
