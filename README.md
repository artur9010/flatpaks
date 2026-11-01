# flatpaks

Flatpak packages, built and published on every push to `master`.

## Install

```
flatpak remote-add --user --if-not-exists artur9010 https://flatpaks.motyka.pro/repo/artur9010.flatpakrepo
flatpak install --user artur9010 dev.playhorizon.horizon
```

`flatpak update` picks up new versions. Single-file `.flatpak` bundles are on [GitHub Releases](https://github.com/artur9010/flatpaks/releases); they don't update on their own.

## Apps

| App | Package |
|---|---|
| [Horizon launcher](https://github.com/horizon-rust/horizon) | `dev.playhorizon.horizon` |

## Adding an app or a version

Each app has a folder named after its app ID, holding `<app-id>.yml` and `<app-id>.metainfo.xml`. The newest `<release>` in the metainfo names the GitHub Release.
