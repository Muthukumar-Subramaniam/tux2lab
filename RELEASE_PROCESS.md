# Release Process for tux2lab

This document guides local release preparation and the push to GitHub. The user then creates the release and tag manually in the GitHub UI. When the user requests a release, follow these steps in order.

Updating this procedure does not authorize running it. Do not run live image builds, pushes, or lab tests merely to validate these instructions. Stop at any failed or unverified gate; do not treat it as passed.

## Step 0: Check If There's Anything to Release

**CRITICAL FIRST STEP** - Before doing anything else:

1. Get commits since last release:
```bash
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

2. **Analyze if commits are user-facing changes:**
   - Release bug fixes, features, enhancements, performance improvements, and corrections affecting installation or operation.
   - Judge impact, not file location. Build, packaging, and CI fixes qualify when they affect delivered artifacts or users, such as preventing a build from deleting running lab infrastructure.
   - Pure release-procedure documentation, repository metadata, or internal refactoring without user impact does not by itself warrant a release.

3. **If no user-facing changes exist:**
   - Respond: "Nothing to release. No user-facing changes since [last version]."
   - **STOP** - do not proceed with release steps

4. **Only if user-facing changes exist:**
   - Proceed to Pre-Release Checklist

## Pre-Release Checklist
1. Review the release diff and ensure all intended changes are committed. Do not include unrelated working-tree changes.
2. Run `bash -n` and `shellcheck --shell=bash` on each shell script changed since the previous release, not only uncommitted edits.
3. Run relevant regression tests for the changed behavior and record results. Use sandboxed tests where available; never run destructive tests against the live lab. In particular, the dnsbinder smoke tests wipe zone files and require a disposable environment.
4. Verify README.md is updated (supported distros, CLI examples, behavior, and the chosen image version).
5. Verify the working tree is clean. An unavailable required check is a blocker to resolve or explicitly discuss with the user, not a successful check.

## Release Steps

### 1. Determine Version Bump
- Read current version from `project_version.json`
- If the user has already approved and prepared a version for this release, retain it. For example, an already-approved `2.1.1` must not be incremented again merely because release preparation is starting.
- Otherwise, analyze git commits since last release to propose the version bump and confirm it with the user.
- Check that the chosen release tag has not already been published. Do not overwrite an existing release.
- Follow Semantic Versioning (MAJOR.MINOR.PATCH):

**MAJOR version (vX.0.0)** - Increment when:
- Breaking changes that require user action
- Incompatible API changes
- Major architectural changes
- Removal of deprecated features
- Changes that break existing workflows

**MINOR version (v2.X.0)** - Increment when:
- New features added in backwards compatible manner
- New commands or subcommands added
- New configuration options added
- Significant enhancements that don't break existing functionality
- New OS distribution support

**PATCH version (v2.0.X)** - Increment when:
- Bug fixes only
- Small enhancements to existing features
- Documentation updates
- Performance improvements
- Code refactoring without behavior changes
- UI/UX improvements (like menu display fixes)

**Analysis Method:**
```bash
# Review commits since last release
git log $(git describe --tags --abbrev=0)..HEAD --oneline

# Look for keywords:
# - "breaking", "incompatible", "removed" → MAJOR
# - "add", "new feature", "enhancement" → MINOR (if significant)
# - "fix", "bug", "improve" → PATCH
```

### 2. Update Version File
- Store the version without a `v` prefix: `{"version": "2.1.1"}`.
- Container image tags and the README image reference use `2.1.1`. The GitHub release tag uses `v2.1.1`.
- If the file already contains the approved version, leave it unchanged. Keep the README image reference aligned.

### 3. Commit Version Bump
If the version or README still has uncommitted release changes, review and commit them:

```bash
git add project_version.json README.md
git commit -m "Bump version to vX.Y.Z"
```

Use the chosen version in commit messages. Skip this commit if these changes are already committed; never create an empty version-bump commit.

### 4. Verify the Release Image
- Require the exact version from `project_version.json` in both GHCR (`ghcr.io/muthukumar-subramaniam/tux2lab-engine`) and Docker Hub (`docker.io/musubram/tux2lab-engine`). Never substitute `latest` for this check.
- Confirm public pulls from both registries using an isolated environment without saved registry credentials or a cached image masking a missing publication. Record the image identities and confirm they match the tested candidate.
- In a disposable lab, verify that deployment actually runs the new image, then run `tux2lab health` and relevant provisioning/lifecycle tests. A healthy existing container running the old image is not evidence that the new image works.
- `container/build-and-push.sh` builds and immediately publishes both the versioned tag and `latest`; it is not a build-only test command. If testing must precede publication, build separately, test that image, and push the tested image by ID without rebuilding it.
- Do not proceed until the image and runtime checks pass. Changes to image inputs after testing require a new candidate and repeated checks.

### 5. Create and Verify Release Tarball
Run from the repository root with a clean working tree. Record the source commit after the approved version and release changes are committed. Package a clean export so ignored files, local credentials, and untracked files cannot accidentally enter the archive.

```bash
set -euo pipefail
SOURCE_COMMIT=$(git rev-parse HEAD)
VERSION=$(jq -er '.version' project_version.json)
RELEASE_WORKDIR=$(mktemp -d)
git archive "${SOURCE_COMMIT}" | tar -x -C "${RELEASE_WORKDIR}"
(
   cd "${RELEASE_WORKDIR}" && bash create-release-tarball.sh
)
mkdir -p latest-release
cp "${RELEASE_WORKDIR}/latest-release/tux2lab.tar.gz" latest-release/tux2lab.tar.gz
```

Run these checks with `pipefail` enabled and stop on any failure:

```bash
set -o pipefail
gzip -t latest-release/tux2lab.tar.gz
tar -tzf latest-release/tux2lab.tar.gz
tar -xOf latest-release/tux2lab.tar.gz project_version.json \
   | jq -e --arg version "${VERSION}" '.version == $version'
gzip -dc latest-release/tux2lab.tar.gz \
   | tar --compare --file=- --directory="${RELEASE_WORKDIR}"
sha256sum latest-release/tux2lab.tar.gz
```

- Review the member list for expected runtime directories and files, including `project_version.json`, `setup/`, `container/`, `shared-functions/`, `common-utils/`, `ksmanager/`, `named-manage/`, `lb-manage/`, `qemu-kvm-manage/`, and `vendor/`.
- Confirm the packager's exclusions are absent: `.git`, `.github`, `.gitignore`, `latest-release`, `docs`, `create-release-tarball.sh`, and `RELEASE_PROCESS.md`. Reject unexpected files or unsafe absolute/parent-relative paths.
- The comparison checks archived contents and file metadata against the clean source export. Review the member list as well: comparison alone does not detect an omitted required file.
- Record the checksum and `SOURCE_COMMIT` for the manual handoff. Remove only the temporary export directory created above after successful verification.

### 6. Commit Tarball
Ensure HEAD still equals `SOURCE_COMMIT` and the only pending change is the verified tarball. If source changed, repeat the applicable tests and packaging steps before continuing.

```bash
git add latest-release/tux2lab.tar.gz
git commit -m "Release vX.Y.Z tarball"
```

### 7. Push to GitHub
Verify the tree is clean and record the final commit containing the tarball. Push that commit; it is the target for the user's manual release tag.

```bash
git push
# Note: Do NOT push tags - user creates GitHub release manually
```

### 8. Generate Release Notes
Fetch previous release from GitHub to match format:
```
https://github.com/Muthukumar-Subramaniam/tux2lab/releases
```

Format (strictly follow this structure):
```markdown
## 📢 Release Notes - vX.Y.Z

Released: [Date in format: Month DD, YYYY]

### 🐛 Bug Fixes

• [Description of bug fix]
• [Another bug fix]

### ✨ Enhancements

• [Description of enhancement]
• [Another enhancement]

### 🔧 Technical Details

• [Technical implementation details]
• [Code changes explanation]
• [Configuration updates]
```

### 9. Manual GitHub Handoff
- Display the release notes in markdown format in chat
- Provide the chosen version, final pushed commit, verified tarball path, checksum, and validation results.
- User manually creates the GitHub release and `vX.Y.Z` tag targeting that final pushed commit.
- User attaches the verified `tux2lab.tar.gz` as the release asset. Committing it to the repository does not attach it to the release.
- After publication, verify that the README download URL resolves to the intended release asset and that its checksum matches the verified tarball.
- GitHub will automatically generate Full Changelog link

## Notes
- Never push git tags - user creates them via GitHub release
- Always check GitHub for previous release format before generating notes
- Keep technical details section comprehensive
- Use bullet points consistently (• not -)
- GitHub automatically generates Full Changelog link, don't include it in notes
