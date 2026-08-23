#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Prints the tag that the currently checked out commit should be released as,
# or nothing at all if it does not warrant a release.
#
# Usage: bin/compute-next-tag.sh
#
# This role tracks one MariaDB version per supported release series
# (`mariadb_container_image_v11_8`, `mariadb_container_image_v12_3`, ...).
# Only the newest tracked series defines the tag, which looks like
# `v<newest MariaDB version>-<release>`:
#
# - if defaults/main.yml points at a newest version that has never been
#   released, the release counter restarts at 0 (`v12.3.2-0`)
# - otherwise the counter is incremented (`v12.3.2-1`), but only if something
#   that actually affects the role has changed since the last release
#
# A bump to an older series (say 11.4) therefore does not produce a misleading
# `v11.4.x` tag - it increments the newest version's counter, and the fix still
# reaches consumers through that release. This matches how this repository has
# been tagged by hand all along.
#
# The version is read from the per-series variables rather than from
# `mariadb_container_image_latest`, for two reasons. The latter is a Jinja
# reference to one of them rather than a literal, so there is no version to
# read there; and it is deliberately allowed to lag behind the newest tracked
# series (12.3 was added while still an RC and `_latest` was pointed back at
# 12.1), while the tags kept following the newest series.
#
# Determining the version from defaults/main.yml, rather than from the commit
# message of the pull request that got merged, makes the result independent of
# the order in which pull requests get merged, and lets any change to the role
# (bugfix, feature, dependency bump) release itself without a human tagging.

set -euo pipefail

repository_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repository_path"

defaults_path='defaults/main.yml'

# Paths that shape the behavior of the role for its consumers. A commit
# touching only other paths (a README fix, CI configuration, Molecule tests)
# does not change what a playbook run does, and releasing it would only create
# churn in the repositories that consume this role.
role_defining_paths=(
	'defaults'
	'meta'
	'tasks'
	'templates'
	'vars'
)

# The version pinned by the highest-numbered mariadb_container_image_v<X>_<Y>.
# The series numbers are sorted numerically and separately, so that 10.11 is
# recognized as older than 11.1 and 12.3 as newer than 12.1.
version="$(sed -nE 's|^mariadb_container_image_v([0-9]+)_([0-9]+):.*mariadb:"?([^"[:space:]]+)"?.*$|\1 \2 \3|p' "$defaults_path" \
	| sort -k1,1n -k2,2n | tail -n1 | cut -d' ' -f3)"

if [ -z "$version" ]; then
	echo >&2 "Could not determine the newest MariaDB version from $defaults_path"
	exit 1
fi

tag_prefix="v${version}-"

# Of all releases of this version, the highest release number. Sorted
# numerically, so that -10 is recognized as newer than -9.
last_release="$(git tag --list "${tag_prefix}*" | sed -e "s|^${tag_prefix}||" | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)"

if [ -z "$last_release" ]; then
	echo >&2 "Version $version has never been released"
	echo "${tag_prefix}0"
	exit 0
fi

previous_tag="${tag_prefix}${last_release}"

if git diff --quiet "$previous_tag" HEAD -- "${role_defining_paths[@]}"; then
	echo >&2 "Nothing affecting the role has changed since $previous_tag"
	exit 0
fi

echo >&2 "The role has changed since $previous_tag"
echo "${tag_prefix}$((last_release + 1))"
