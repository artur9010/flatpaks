# Working in this repo

Flatpak manifests, published to `https://flatpaks.motyka.pro/repo/` and GitHub Releases.

## Layout

One folder per app, named after the app ID, holding `<app-id>.yml` and `<app-id>.metainfo.xml`.

`publish.yml` and `update.yml` treat every `*/*.yml` as an app, so:

- Keep one `.yml` per folder. Name helper modules `.json` or put them in a subfolder.
- Manifests must be `.yml`. `.yaml` and `.json` manifests are skipped silently.

## Publishing

Anything that lands on `master` publishes straight away. There is no staging.

`.github/workflows/build.yml` runs `flatpak-builder` on each PR for the apps it changes. A ruleset on `master` requires its `flatpak-builder` check, so a PR that doesn't build can't be merged. Repo admins bypass the ruleset, which keeps direct pushes to `master` working, and they also get an option to merge a failing PR. Don't rename the job without updating the ruleset, or every PR will wait for a check that never arrives.

`.github/workflows/publish.yml` rebuilds only apps whose folder hash changed. The Flatpak repo (`repo/`) and the hashes (`built/`) live in the `flatpaks` Cloudflare R2 bucket. Bundles go to a GitHub Release named `<app-id>-<version>`, using the newest `<release>` in the metainfo.

The R2 upload order must stay objects, then `summary`, then hashes. Otherwise clients can see a version whose files aren't there yet, or a failed upload never gets retried.

## Adding an app

1. Create the folder, manifest and metainfo.
2. Prefer the official upstream release binary when a source build would lose features.
3. Add `x-checker-data` with `is-main-source: true` to the main source.
4. Pin other sources to a commit, with a `sha256`.
5. Keep the metainfo `<releases>` newest first.

## Updating an app

`.github/workflows/update.yml` runs `flatpak-external-data-checker` hourly and opens a PR when an app has a new version. Merging it ships the update. Run it by hand from the Actions tab, or with `gh workflow run update.yml`.

The PRs are opened by the `craftum-renovate-bot` GitHub App, using the `APP_CLIENT_ID` repo variable and the `APP_PRIVATE_KEY` secret. Don't switch it to `GITHUB_TOKEN`: PRs opened that way wait for manual approval before `build.yml` runs. The app needs read and write access to contents, pull requests and workflows on this repo. Without workflows, force-pushing an update branch made before a workflow change on `master` fails with `fatal error in commit_refs`.

Each app gets one PR, from the `update/<app-id>` branch. A newer version force-pushes that branch, so the open PR always holds the latest one. Closing a PR doesn't skip its version: the next run opens it again while upstream is still newer.

Runtime versions and GitHub Action versions aren't covered, so bump those by hand.

## Update reviews

`.github/workflows/update-review.yml` posts an AI review as a sticky comment (marker `<!-- update-review -->`) on every PR from an `update/` branch. It covers the risk, the upstream source changes, anything that breaks the sandbox or the build, impact on the manifest, package maintenance and upgrade steps. Its job `update-review` is required by the `master` ruleset, so an update that wasn't reviewed can't be merged. Other PRs skip the job, which counts as passing. Don't rename the job without updating the ruleset.

- `.github/scripts/upstream-source.sh` finds every source whose `url` or `commit` changed, in all `.yml` and `.json` files of an app folder. It works out the upstream repo from the URL (GitHub releases, archives, raw files, git sources) and writes the commits and source diff between the old and new versions as `<app-id>/upstream/<repo>/part-NNN.txt`, plus both versions' GitHub release notes. When two release tags are the same commit, or a tag is missing, it diffs the unpacked release archives instead. Sources not on GitHub are reported as not available, and the review goes on without them.
- `.github/upstream-sources.yaml` scopes a repo's diff to some paths, for monorepos like Horizon's. Its `cargo` entries add the path dependencies of those Cargo manifests. A repo that isn't listed is diffed whole. Diffs over `MAX_SOURCE_BYTES` are cut, and the comment says how much was reviewed.
- Each part has random start and end tokens, kept outside the model's directory. `.github/scripts/review-check.sh` accepts a session only if one non-truncated tool output holds both tokens of every part, and an `exa_web_search_exa` query names each new version. A rejected session is retried as a fresh one with the list of what it missed, up to 3 attempts. If none passes, the PR gets a `⛔ Not reviewed` comment and the job fails.
- The `### Sources checked` section is written by `review-check.sh` from the session's tool calls, not by the model.
- The model is opencode 2.x, the GitHub release binary pinned in `OPENCODE_VERSION` and `OPENCODE_SHA256` (2.x isn't on npm). It runs `openrouter/z-ai/glm-5.3-flash` on OpenRouter, with the key in the `OPENROUTER_API_KEY` secret, passed only to the review step. OpenCode Zen's free models don't work from GitHub runners: their shared IPs hit Zen's free usage limit straight away. Bump the version and the model by hand, and keep `MODEL` in the workflow and `model` in `.github/opencode/opencode.json` the same. The footer of each comment shows the tokens and cost of its review.
- The model's tools are set in `.github/opencode/opencode.json`: read, `git`, read-only `ls`/`cat`/`head`/`tail`/`grep`/`diff`/…, the Exa MCP (`exa_web_search_exa`, `exa_web_fetch_exa`, no key, it loads a few seconds into the session) and the built-in `webfetch`. The output format is in `.github/opencode/prompt.md`. It gets no GitHub token, and the job may run up to 300 minutes.
- The OpenRouter key is in the model's environment, and the model reads untrusted upstream code, so the deny rules keep it from reading the key. They block `$`, `../`, absolute paths, `~`, `/proc`, `environ`, `-c` flags, `--config*`, `git config`, aliases, `!`, `*-pack` and `ext::`, and the `external_directory` action blocks reading files outside the review directory. Re-check them whenever you add a command to the allow list. Give the key a credit limit on OpenRouter.
- Check denied tool calls with `gh run view <id> --log | grep -a "Permission denied"`. To satisfy a PR's check, use **Re-run jobs** on the PR's run. `gh workflow run update-review.yml -f pr=<n>` refreshes the comment but doesn't count as the PR's check. Locally, use `nix-shell -p opencode` (a 2.x build) and `opencode run --standalone`.

## Testing locally

```
nix-shell -p flatpak-builder --run 'flatpak-builder --user --install --force-clean build <app-id>/<app-id>.yml'
nix-shell -p appstream --run 'appstreamcli validate --no-net <app-id>/<app-id>.metainfo.xml'
nix-shell -p actionlint --run 'actionlint'
```

## Secrets

`GPG_PRIVATE_KEY`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and `APP_PRIVATE_KEY` are GitHub secrets. Never commit them or paste them into a chat.

Don't change the signing key. Every user would have to re-add the remote.

## Recovering a failed release

If a build uploaded but the release step failed, use **Re-run failed jobs**. A full re-run treats the app as unchanged and skips the release.
