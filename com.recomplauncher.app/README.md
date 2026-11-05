# RecompLauncher

## Host access through `flatpak`

Some recomps are released as `.flatpak` bundles. To install and start them, the app can talk to the host's Flatpak (`--talk-name=org.freedesktop.Flatpak`). Its `flatpak` command is a wrapper around `flatpak-spawn --host flatpak`.

That permission gets around the sandbox. Through it, the app can run any command on the host as you, not only `flatpak`.

To turn it off, run this. Recomps released as `.flatpak` bundles then can't be installed or started from the launcher, and other recomps aren't affected:

```
flatpak override --user --no-talk-name=org.freedesktop.Flatpak com.recomplauncher.app
```

Undo it with:

```
flatpak override --user --reset com.recomplauncher.app
```

`--reset` clears all of your overrides for this app, not only this one.
