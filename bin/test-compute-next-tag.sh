#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Exercises bin/compute-next-tag.sh against throwaway git repositories.
#
# Usage: bin/test-compute-next-tag.sh
#
# Every scenario creates a repository in a temporary directory, gives it role
# files and a release history, and then replays a series of merges through the
# real script, tagging as it goes just like the autotag workflow does. This
# repository is never touched and no network access is needed.

set -euo pipefail

script_under_test="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/compute-next-tag.sh"

failures=0
workdir=''

cleanup() {
	cd /
	if [ -n "$workdir" ]; then
		rm -rf "$workdir"
		workdir=''
	fi
}

trap cleanup EXIT

# Writes a defaults/main.yml shaped like the real one: several supported
# series, each pinning one version, plus the `_latest` pointer that names one
# of them rather than carrying a version of its own.
write_defaults() {
	cat > defaults/main.yml <<-'YAML'
		mariadb_identifier: 'mariadb'

		mariadb_container_image_registry_prefix: docker.io/

		mariadb_container_image_v11_4: "{{ mariadb_container_image_registry_prefix }}mariadb:11.4.12"
		mariadb_container_image_v11_8: "{{ mariadb_container_image_registry_prefix }}mariadb:11.8.8"
		mariadb_container_image_v12_1: "{{ mariadb_container_image_registry_prefix }}mariadb:12.1.2"
		mariadb_container_image_v12_3: "{{ mariadb_container_image_registry_prefix }}mariadb:12.3.2"
		mariadb_container_image_latest: "{{ mariadb_container_image_v12_1 }}"
	YAML
}

# Starts a scenario with a repository whose newest series is 12.3 at 12.3.2,
# which has already seen two releases of it (v12.3.2-0 and v12.3.2-1).
scenario() {
	echo "$1"

	cleanup
	workdir="$(mktemp -d)"

	mkdir -p "$workdir/bin" "$workdir/defaults" "$workdir/tasks" "$workdir/templates"
	cp "$script_under_test" "$workdir/bin/"
	cd "$workdir"

	git init -q -b main .
	git config user.email 'test@example.com'
	git config user.name 'Test'
	git config commit.gpgsign false

	write_defaults
	printf 'placeholder\n' > tasks/main.yml
	printf 'placeholder\n' > templates/env.j2
	printf 'placeholder\n' > README.md

	git add -A
	git commit -qm 'Initial commit'

	local release_number
	for release_number in 0 1; do
		git tag "v12.3.2-$release_number"
	done
}

# Applies a change, commits it, and tags whatever the script says it should be.
# Prints the tag, or nothing when the script decided against a release.
merge() {
	local change="$1" tag

	eval "$change"
	git add -A
	git commit -qm 'Merge'

	tag="$(bin/compute-next-tag.sh 2>/dev/null)"

	if [ -n "$tag" ]; then
		git tag "$tag"
	fi

	printf '%s' "$tag"
}

expect() {
	local description="$1" expected="$2" actual="$3"

	if [ "$actual" = "$expected" ]; then
		printf '  ok   | %s -> %s\n' "$description" "${actual:-no release}"
	else
		printf '  FAIL | %s -> expected %s, got %s\n' "$description" "${expected:-no release}" "${actual:-no release}"
		failures=$((failures + 1))
	fi
}

bump_newest="sed -i 's|mariadb:12.3.2|mariadb:12.3.3|' defaults/main.yml"
revert_newest="sed -i 's|mariadb:12.3.3|mariadb:12.3.2|' defaults/main.yml"
bump_older="sed -i 's|mariadb:11.8.8|mariadb:11.8.9|' defaults/main.yml"
add_newer_series="printf 'mariadb_container_image_v12_4: \"{{ mariadb_container_image_registry_prefix }}mariadb:12.4.1\"\n' >> defaults/main.yml"
add_ancient_series="printf 'mariadb_container_image_v5_5: \"{{ mariadb_container_image_registry_prefix }}mariadb:5.5.68\"\n' >> defaults/main.yml"
repoint_latest="sed -i 's|mariadb_container_image_v12_1 }}|mariadb_container_image_v11_8 }}|' defaults/main.yml"
edit_task="printf 'a task\n' >> tasks/main.yml"
edit_template="printf 'a line\n' >> templates/env.j2"
edit_readme="printf 'documentation\n' >> README.md"
edit_script="printf '# a comment\n' >> bin/compute-next-tag.sh"

# The two merge orders below apply the same updates and must each end up with
# every update released exactly once, whichever order they arrive in.

scenario 'A version bump merged before other role changes'
expect 'version bump' v12.3.3-0 "$(merge "$bump_newest")"
expect 'task edit'    v12.3.3-1 "$(merge "$edit_task")"
expect 'template'     v12.3.3-2 "$(merge "$edit_template")"

scenario 'A version bump merged after other role changes'
expect 'task edit'    v12.3.2-2 "$(merge "$edit_task")"
expect 'version bump' v12.3.3-0 "$(merge "$bump_newest")"

scenario 'Commits that do not affect the role'
expect 'README'   ''        "$(merge "$edit_readme")"
expect 'a script' ''        "$(merge "$edit_script")"
expect 'a task'   v12.3.2-2 "$(merge "$edit_task")"

scenario 'Release numbers past 9'
for release_number in 2 3 4 5 6 7 8 9 10; do
	git tag "v12.3.2-$release_number"
done
expect 'a task' v12.3.2-11 "$(merge "$edit_task")"

scenario 'Reverting to an already released version'
merge "$bump_newest" > /dev/null
# The role is now identical to what v12.3.2-1 already published, so there is
# nothing new to release.
expect 'a revert' ''        "$(merge "$revert_newest")"

scenario 'Reverting to an already released version, with a change'
merge "$bump_newest" > /dev/null
expect 'a revert' v12.3.2-2 "$(merge "$revert_newest && $edit_task")"

# A bugfix release of a series that is not the newest one still has to reach
# consumers, and it does so under the newest series' version. Tagging it
# `v11.8.9-0` would advertise a MariaDB version this role does not install by
# default and would sort below the tags already published.
scenario 'A bump of an older series releases under the newest series'
expect 'an older series bump' v12.3.2-2 "$(merge "$bump_older")"

# Adding a series is how a new MariaDB major or minor arrives here, and the
# tag has to follow it rather than keep counting up from the previous series.
scenario 'A newly added series takes over the tag'
expect 'a new series' v12.4.1-0 "$(merge "$add_newer_series")"

# `mariadb_container_image_latest` is a Jinja reference to one of the series
# variables and is allowed to lag behind the newest one (12.3 was added while
# still an RC, with `_latest` left pointing at 12.1). Whatever it points at,
# the tag follows the newest tracked series.
scenario 'The _latest pointer does not define the tag'
expect 'repointing _latest' v12.3.2-2 "$(merge "$repoint_latest")"

# Series numbers are numbers: as text, "5" sorts after "12" and MariaDB 5.5
# would look like the newest series this role knows about.
scenario 'Series are compared numerically, not as text'
expect 'an ancient series' v12.3.2-2 "$(merge "$add_ancient_series")"

# The same trap one level down: as text, "10.11" sorts before "10.2".
scenario 'Series numbers are compared field by field'
cat > defaults/main.yml <<-'YAML'
	mariadb_container_image_v10_2: "{{ mariadb_container_image_registry_prefix }}mariadb:10.2.44"
	mariadb_container_image_v10_11: "{{ mariadb_container_image_registry_prefix }}mariadb:10.11.18"
YAML
expect 'a rewritten defaults file' v10.11.18-0 "$(merge 'true')"

if [ "$failures" -gt 0 ]; then
	echo >&2 "$failures scenario(s) behaved unexpectedly"
	exit 1
fi

echo 'All scenarios behaved as expected'
