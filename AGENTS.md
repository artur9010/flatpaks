# Working in this repo

Flatpak manifests, published to `https://flatpaks.motyka.pro/repo/` and GitHub Releases.

## Layout

One folder per app, named after the app ID, holding `<app-id>.yml` and `<app-id>.metainfo.xml`.

`publish.yml` and `update.yml` treat every `*/*.yml` as an app, so:

- Keep one `.yml` per folder. Name helper modules `.json` or put them in a subfolder.
- Manifests must be `.yml`. `.yaml` and `.json` manifests are skipped silently.

## Publishing

Anything that lands on `master` publishes straight away. There are no PR builds and no staging.

`.github/workflows/publish.yml` rebuilds only apps whose folder hash changed. The Flatpak repo (`repo/`) and the hashes (`built/`) live in the `flatpaks` Cloudflare R2 bucket. Bundles go to a GitHub Release named `<app-id>-<version>`, using the newest `<release>` in the metainfo.

The R2 upload order must stay objects, then `summary`, then hashes. Otherwise clients can see a version whose files aren't there yet, or a failed upload never gets retried.

## Adding an app

1. Create the folder, manifest and metainfo.
2. Prefer the official upstream release binary when a source build would lose features.
3. Add `x-checker-data` with `is-main-source: true` to the main source.
4. Pin other sources to a commit, with a `sha256`.
5. Keep the metainfo `<releases>` newest first.

## Updating an app

`.github/workflows/update.yml` runs `flatpak-external-data-checker` daily and opens a PR for each outdated app. Merging it ships the update. Run it by hand from the Actions tab, or with `gh workflow run update.yml`.

If several PRs pile up, merge the newest and close the others.

Runtime versions and GitHub Action versions aren't covered, so bump those by hand.

## Testing locally

```
nix-shell -p flatpak-builder --run 'flatpak-builder --user --install --force-clean build <app-id>/<app-id>.yml'
nix-shell -p appstream --run 'appstreamcli validate --no-net <app-id>/<app-id>.metainfo.xml'
nix-shell -p actionlint --run 'actionlint'
```

## Secrets

`GPG_PRIVATE_KEY`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` are GitHub secrets. Never commit them or paste them into a chat.

Don't change the signing key. Every user would have to re-add the remote.

## Recovering a failed release

If a build uploaded but the release step failed, use **Re-run failed jobs**. A full re-run treats the app as unchanged and skips the release.
