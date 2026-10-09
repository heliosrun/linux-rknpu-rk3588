#!/usr/bin/env bash
# Refresh the driver-only vendor-diff anchor branch.
#
# The linked GitHub compare is:
#   vendor/v0.9.8...diff/vendor-v0.9.8
#
# GitHub compares whole trees, so this anchor branch intentionally contains
# only main's driver/ subtree. Its history retains the pristine vendor
# commit, allowing GitHub to compute the comparison. Non-driver files in
# main therefore do not appear in the linked compare.
#
# Usage:
#   scripts/update-vendor-diff.sh [--dry-run] [--push] [--remote origin] \\
#     [--main main] [--vendor vendor/v0.9.8] [--diff diff/vendor-v0.9.8]
set -euo pipefail

REMOTE="origin"
MAIN="main"
VENDOR="vendor/v0.9.8"
DIFF="diff/vendor-v0.9.8"
PUSH=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: update-vendor-diff.sh [--dry-run] [--push] [--remote NAME] [--main REF] [--vendor REF] [--diff BRANCH]
EOF
}

while (($#)); do
  case "$1" in
    --push) PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --remote) REMOTE="${2:?}"; shift ;;
    --main) MAIN="${2:?}"; shift ;;
    --vendor) VENDOR="${2:?}"; shift ;;
    --diff) DIFF="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

resolve_commit() {
  local name="$1" resolved=""
  if resolved="$(git rev-parse --verify --quiet "${name}^{commit}")"; then
    printf '%s' "$resolved"
    return 0
  fi
  if resolved="$(git rev-parse --verify --quiet "${REMOTE}/${name}^{commit}")"; then
    printf '%s' "$resolved"
    return 0
  fi
  echo "error: cannot resolve ref '$name' or '${REMOTE}/$name'" >&2
  exit 1
}

main_commit="$(resolve_commit "$MAIN")"
vendor_commit="$(resolve_commit "$VENDOR")"
driver_tree="$(git rev-parse --verify "${main_commit}:driver")"
new_tree="$(printf '040000 tree %s\tdriver\n' "$driver_tree" | git mktree)"
ref="refs/heads/${DIFF}"
parents=()
old_commit=""

if git rev-parse --verify --quiet "$ref" >/dev/null; then
  old_commit="$(git rev-parse --verify "$ref")"
  if ! git merge-base --is-ancestor "$vendor_commit" "$old_commit"; then
    echo "error: ${DIFF} does not contain ${VENDOR}; refusing to rewrite it" >&2
    exit 1
  fi
  old_driver_tree=""
  if git rev-parse --verify --quiet "${old_commit}:driver" >/dev/null; then
    old_driver_tree="$(git rev-parse --verify "${old_commit}:driver")"
  fi
  old_top_level="$(git ls-tree --name-only "$old_commit")"
  if [ "$old_driver_tree" = "$driver_tree" ] && [ "$old_top_level" = "driver" ]; then
    echo "vendor diff anchor already matches ${MAIN}:${driver_tree} ($main_commit)"
    exit 0
  fi
  parents=(-p "$old_commit" -p "$main_commit")
else
  parents=(-p "$vendor_commit" -p "$main_commit")
fi

message="chore(diff): refresh driver-only vendor compare

Main: $main_commit
Vendor: $vendor_commit
Driver tree: $driver_tree"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'main=%s\nvendor=%s\ndriver_tree=%s\nanchor_tree=%s\n' \
    "$main_commit" "$vendor_commit" "$driver_tree" "$new_tree"
  exit 0
fi

new_commit="$(git commit-tree "$new_tree" "${parents[@]}" -m "$message")"
if [ -n "$old_commit" ]; then
  git update-ref -m "$message" "$ref" "$new_commit" "$old_commit"
else
  git update-ref -m "$message" "$ref" "$new_commit"
fi

if [ "$PUSH" -eq 1 ]; then
  git push "$REMOTE" "${ref}:${ref}"
fi

printf '%s\n' "$new_commit"
