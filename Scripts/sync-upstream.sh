#!/bin/bash
# Pull upstream into `main`, surviving upstream's periodic force-pushes. Run this instead of a bare
# `git merge upstream/main` — see custom_docs/CUSTOM.md#pulling-in-upstream.
#
# Upstream rebases and force-pushes `main`, so every commit gets a new SHA while the content stays the
# same. A plain merge then falls back to an ancient shared base and explodes into hundreds of spurious
# add/add conflicts over content you already hold. This probes the merge first: a genuinely new,
# conflict-free advance is merged normally; a rewritten history is re-recorded with `-s ours` (keeping
# your tree exactly, 0 conflicts), and the upstream commits that were NOT pulled are listed so you can
# cherry-pick the features you want.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

git rev-parse --verify --quiet upstream/HEAD >/dev/null 2>&1 || git remote get-url upstream >/dev/null 2>&1 || {
    echo "✗ no 'upstream' remote. Add it:  git remote add upstream https://github.com/abue-ammar/tinycast.git" >&2
    exit 2
}

git diff --quiet && git diff --cached --quiet || {
    echo "✗ working tree not clean — commit or stash first, a merge is not a place to lose edits." >&2
    exit 2
}

echo "· fetching upstream…"
git fetch --quiet upstream || { echo "✗ git fetch upstream failed" >&2; exit 1; }

if git merge-base --is-ancestor upstream/main HEAD; then
    echo "✓ already in sync with upstream/main (0 behind)"
    exit 0
fi

# What upstream carries that `main` does not already hold *by patch* — the genuinely new work, immune
# to the SHA churn a force-push causes. This is the cherry-pick list when we fall back to `-s ours`.
new=$(git log --oneline --no-merges --left-only --cherry-pick upstream/main...main)
newcount=$(printf '%s\n' "$new" | grep -c . || true)

# Probe without keeping the result: a clean merge is a real advance; conflicts mean a rewritten history.
if git merge --no-commit --no-ff upstream/main >/dev/null 2>&1; then
    git commit --no-edit >/dev/null
    echo "✓ merged upstream/main ($newcount new commits)"
else
    git merge --abort 2>/dev/null
    git merge -s ours --no-edit upstream/main \
        -m "Merge upstream/main (rewritten history; content already present, keep ours)" >/dev/null
    echo "✓ upstream force-pushed a rewritten history — re-recorded with -s ours (0 behind, 0 conflicts)."
    if [ "$newcount" -gt 0 ]; then
        echo "  ↳ $newcount upstream commits were NOT pulled. Cherry-pick the ones you want:"
        printf '%s\n' "$new" | sed 's/^/      /'
    fi
fi

echo "· push when ready:  git push origin main   (as jhasubhash)"
