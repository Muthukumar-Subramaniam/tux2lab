# Release Process for tux2lab

This document guides the automated release process. When the user says "release", follow these steps in order.

## Step 0: Check If There's Anything to Release

**CRITICAL FIRST STEP** - Before doing anything else:

1. Get commits since last release:
```bash
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

2. **Analyze if commits are user-facing changes:**
   - ✅ **Release these**: Bug fixes, new features, enhancements, performance improvements, UI/UX changes
   - ❌ **DO NOT release these**: 
     - Changes to `RELEASE_PROCESS.md` or `.github/` directory
     - Changes to `create-release-tarball.sh` or CI/CD scripts
     - Documentation about the release process itself
     - Internal tooling or meta changes

3. **If no user-facing changes exist:**
   - Respond: "Nothing to release. No user-facing changes since [last version]."
   - **STOP** - do not proceed with release steps

4. **Only if user-facing changes exist:**
   - Proceed to Pre-Release Checklist

## Pre-Release Checklist
1. Ensure all changes are committed
2. Run syntax checks on modified shell scripts
3. Verify no uncommitted changes remain
4. Verify README.md is updated (supported distros table, CLI examples, any user-facing docs)

## Release Steps

### 1. Determine Version Bump
- Read current version from `project_version.json`
- Analyze git commits since last release to determine version bump type
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
```bash
# Update project_version.json with new version
# Format: v2.0.X
```

### 3. Commit Version Bump
```bash
git add project_version.json
git commit -m "Bump version to vX.Y.Z"
```

### 4. Create Release Tarball
```bash
bash create-release-tarball.sh
```

### 5. Commit Tarball
```bash
git add latest-release/tux2lab.tar.gz
git commit -m "Release vX.Y.Z tarball"
```

### 6. Push to GitHub
```bash
git push
# Note: Do NOT push tags - user creates GitHub release manually
```

### 7. Generate Release Notes
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

### 8. Present Release Notes
- Display the release notes in markdown format in chat
- User will manually create GitHub release with these notes
- User handles git tag creation via GitHub release UI
- GitHub will automatically generate Full Changelog link

## Notes
- Never push git tags - user creates them via GitHub release
- Always check GitHub for previous release format before generating notes
- Keep technical details section comprehensive
- Use bullet points consistently (• not -)
- GitHub automatically generates Full Changelog link, don't include it in notes
