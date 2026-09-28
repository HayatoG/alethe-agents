# Fork workflow for `mac-native-v2`

The native macOS work is published to a personal fork, not to the original repository. The pull
request to the original is opened manually by the owner, later, with a detailed description.

## Remotes

| Remote   | URL                                          | Role                                   |
| -------- | -------------------------------------------- | -------------------------------------- |
| `origin` | `https://github.com/Kc1t/alethe-agents.git`   | Original repository. Fetch only.       |
| `fork`   | `https://github.com/HayatoG/alethe-agents.git` | Public fork. `mac-native-v2` pushes here. |

`mac-native-v2` tracks `fork/mac-native-v2`, so a plain `git push` / `git pull` on that branch
talks to the fork. The `HayatoG` account also has WRITE access to `origin`: pushing there by mistake
would publish the branch on the original repository, so always name the remote explicitly.

## Rules

- Never push, tag, or release without explicit authorization from the owner at that moment.
  Authorization for one push does not carry over to the next.
- Push only `mac-native-v2`. The per-task helper branches (`mac-native-v2-p4-*` … `-p7-*`,
  `mac-native-v2-fix-*`) stay local.
- Commits carry no co-author trailer or tool signature.
- The fork is public: everything pushed is visible to anyone.

## One-time setup (already done on 2026-09-26)

```bash
gh repo fork Kc1t/alethe-agents --clone=false --default-branch-only
git remote add fork https://github.com/HayatoG/alethe-agents.git
git push -u fork mac-native-v2
```

## Before every push

Scan the commits that are about to be published for secrets and personal data:

```bash
R=fork/mac-native-v2..mac-native-v2
# Token patterns in added lines — fixtures and SecretRedactor tests are expected hits.
git log -p $R --no-color | grep -E '^\+' | grep -nE \
  '(sk-ant-|ghp_|gho_|github_pat_|xox[bpa]-|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|access_token|refresh_token|Bearer )'
# Sensitive files added.
git log $R --name-only --diff-filter=A --format= | sort -u | \
  grep -iE '(\.env|\.pem|\.p12|\.key$|xcuserdata|\.bak-|\.ai-memory\.toml|\.DS_Store)'
# Absolute personal paths.
git log -p $R --no-color | grep -E '^\+' | grep -c "$HOME"
# Authors and co-author trailers.
git log $R --format='%an <%ae>' | sort | uniq -c
git log $R --format='%b' | grep -ci 'co-authored'
```

The first push (295 commits, `origin/main..mac-native-v2`) was scanned this way: every token hit was
test data (`FIXTURE-SPOTIFY-*`, `AKIAIOSFODNN7EXAMPLE`, redactor samples), no sensitive files, no
personal paths, one author, no co-author trailers. The author e-mail is public in the commits; use
the GitHub `noreply` address if that should change for future commits.

## Updating the branch

```bash
git push                        # mac-native-v2 → fork/mac-native-v2 (after authorization)
git fetch origin                # bring in new work from the original
git merge origin/main           # on mac-native-v2, when the owner asks for a sync
```

## Publishing a preview build (after authorization)

The native app's preview DMG is attached to a GitHub release on the fork (currently
`mac-native-v2-preview.1`), never on `origin`. The app is signed with the local identity only and is
not notarized, so the release notes carry the quarantine workaround from the README.

```bash
AletheNative/Scripts/make-dmg.sh              # Release build + branded DMG (add --skip-build to reuse)
git push fork mac-native-v2                   # after the pre-push scan above
git tag -f mac-native-v2-preview.1 <commit> && git push -f fork refs/tags/mac-native-v2-preview.1
gh release upload mac-native-v2-preview.1 -R HayatoG/alethe-agents \
  AletheNative/build/Alethe-macOS-universal.dmg --clobber
```

Then update the SHA-256 and the source commit in the release notes. Moving the tag can reset the
release's pre-release flag; check it afterwards and keep whatever the owner chose.

## Opening the pull request (manual)

On GitHub, compare `Kc1t/alethe-agents:main` ← `HayatoG/alethe-agents:mac-native-v2`
(<https://github.com/HayatoG/alethe-agents/pull/new/mac-native-v2>). Useful sources for the
description: `docs/MAC_NATIVE_V2_PLAN.md` (phase status and test results) and the `[Unreleased]`
section of `docs/CHANGELOG.md`.
