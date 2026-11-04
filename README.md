# flatpaks

Flatpak packages, built and published on every push to `master`.

## Install

```
flatpak remote-add --user --if-not-exists artur9010 https://flatpaks.motyka.pro/repo/artur9010.flatpakrepo
flatpak install --user artur9010 dev.playhorizon.horizon
```

If it says a runtime "was not found", you probably have Flathub only as a system remote, and `--user` installs can't use it. Add Flathub for your user too, then run the install again:

```
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

`flatpak update` picks up new versions. Single-file `.flatpak` bundles are on [GitHub Releases](https://github.com/artur9010/flatpaks/releases); they don't update on their own.

## Apps

| App | Package |
|---|---|
| [Horizon launcher](https://github.com/horizon-rust/horizon) | `dev.playhorizon.horizon` |

## Adding an app or a version

Each app has a folder named after its app ID, holding `<app-id>.yml` and `<app-id>.metainfo.xml`. The newest `<release>` in the metainfo names the GitHub Release.

New versions normally arrive as a bot pull request, checked for hourly. It can only be merged once it builds, and merging it publishes the update. See [AGENTS.md](AGENTS.md) for details.
