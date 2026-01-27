#!/bin/bash

set -euo pipefail

REPO="${REPO:-}"
REPOS="${REPOS:-}"
ORG="${ORG:-}"
NAME="${NAME:-}"
PAT_TOKEN="${PAT_TOKEN:-}"
REG_TOKEN="${REG_TOKEN:-}"
REMOVE_ON_EXIT="${REMOVE_ON_EXIT:-}"

TEMPLATE_DIR=/home/docker/actions-runner-template
BASE_DIR=/home/docker

if [ -z "$NAME" ]; then
	echo "Error: NAME is required."
	exit 1
fi

scope_count=0
[ -n "$REPOS" ] && scope_count=$((scope_count + 1))
[ -n "$REPO" ] && scope_count=$((scope_count + 1))
[ -n "$ORG" ] && scope_count=$((scope_count + 1))
if [ "$scope_count" -ne 1 ]; then
	echo "Error: set exactly one of REPOS, REPO, ORG."
	exit 1
fi

if [ -n "$REPOS" ] && [ -z "$PAT_TOKEN" ]; then
	echo "Error: PAT_TOKEN is required for REPOS."
	exit 1
fi

# Prepare template directory (runner files without per-runner state)
if [ ! -d "$TEMPLATE_DIR" ]; then
	if [ -d /home/docker/actions-runner ]; then
		mv /home/docker/actions-runner "$TEMPLATE_DIR"
	else
		echo "Error: runner template missing."
		exit 1
	fi
fi

gh_token() {
	local token_url="$1"
	local token
	token=$(curl -s -X POST -H "Authorization: token ${PAT_TOKEN}" \
		-H "Accept: application/vnd.github.v3+json" \
		"${token_url}" | jq -r .token)
	if [ -z "$token" ] || [ "$token" = "null" ]; then
		return 1
	fi
	echo "$token"
}

runner_exists() {
	local repo="$1"
	local runner_name="$2"

	local resp
	resp=$(curl -s -H "Authorization: token ${PAT_TOKEN}" \
		-H "Accept: application/vnd.github.v3+json" \
		"https://api.github.com/repos/${repo}/actions/runners?per_page=100")

	if echo "$resp" | jq -e .runners >/dev/null 2>&1; then
		echo "$resp" | jq -e --arg name "$runner_name" '.runners[]? | select(.name == $name)' >/dev/null 2>&1
		return $?
	fi

	return 2
}

declare -a RUNNER_DIRS
declare -a RUNNER_REPOS
declare -a RUNNER_PIDS

register_runner() {
	local runner_dir="$1"
	local scope_url="$2"
	local reg_token_url="$3"
	local label="$4"
	local runner_name="$5"

	local token="$REG_TOKEN"
	if [ -n "$PAT_TOKEN" ]; then
		token=$(gh_token "$reg_token_url") || {
			echo "Error: token fetch failed (${label})"
			return 1
		}
	fi
	if [ -z "$token" ]; then
		echo "Error: missing token (${label})"
		return 1
	fi

	echo "Register: ${label} (${runner_name})"
	cd "$runner_dir" || exit
	./config.sh --unattended --replace --url "$scope_url" --token "$token" --name "$runner_name"
}

start_runner() {
	local runner_dir="$1"
	local label="$2"
	cd "$runner_dir" || exit
	stdbuf -oL -eL ./run.sh 2>&1 | sed -u "s/^/[${label}] /" &
	echo $!
}

if [ -n "$REPOS" ]; then
	IFS=',' read -r -a repos <<<"$REPOS"
	idx=0
	for repo in "${repos[@]}"; do
		repo_trimmed=$(echo "$repo" | xargs)
		if [ -z "$repo_trimmed" ]; then
			continue
		fi

		repo_safe=$(echo "$repo_trimmed" | tr '/' '-')
		runner_name="${NAME}-${repo_safe}"
		runner_dir="${BASE_DIR}/actions-runner-${idx}"

		scope_url="https://github.com/${repo_trimmed}"
		reg_token_url="https://api.github.com/repos/${repo_trimmed}/actions/runners/registration-token"

		if [ ! -d "$runner_dir" ]; then
			cp -a "$TEMPLATE_DIR" "$runner_dir"
		fi

		needs_config=0
		if [ ! -f "$runner_dir/.runner" ]; then
			needs_config=1
		else
			if [ -n "$PAT_TOKEN" ]; then
				if runner_exists "$repo_trimmed" "$runner_name"; then
					echo "Configured: ${repo_trimmed}"
				else
					echo "Reconfigure: ${repo_trimmed}"
					needs_config=1
				fi
			else
				echo "Configured: ${repo_trimmed}"
			fi
		fi

		if [ "$needs_config" -eq 1 ]; then
			rm -rf "$runner_dir"
			cp -a "$TEMPLATE_DIR" "$runner_dir"
			if ! register_runner "$runner_dir" "$scope_url" "$reg_token_url" "$repo_trimmed" "$runner_name"; then
				echo "Skip: ${repo_trimmed}"
				idx=$((idx + 1))
				continue
			fi
		fi

		RUNNER_DIRS+=("$runner_dir")
		RUNNER_REPOS+=("$repo_trimmed")

		idx=$((idx + 1))
	done
else
	runner_dir="${BASE_DIR}/actions-runner-0"
	if [ ! -d "$runner_dir" ]; then
		cp -a "$TEMPLATE_DIR" "$runner_dir"
	fi

	if [ -n "$ORG" ]; then
		scope_url="https://github.com/${ORG}"
		reg_token_url="https://api.github.com/orgs/${ORG}/actions/runners/registration-token"
		remove_token_url="https://api.github.com/orgs/${ORG}/actions/runners/remove-token"
		label="$ORG"
	else
		scope_url="https://github.com/${REPO}"
		reg_token_url="https://api.github.com/repos/${REPO}/actions/runners/registration-token"
		remove_token_url="https://api.github.com/repos/${REPO}/actions/runners/remove-token"
		label="$REPO"
	fi

	RUNNER_DIRS+=("$runner_dir")
	RUNNER_REPOS+=("$label")

	if [ ! -f "$runner_dir/.runner" ]; then
		rm -rf "$runner_dir"
		cp -a "$TEMPLATE_DIR" "$runner_dir"
		register_runner "$runner_dir" "$scope_url" "$reg_token_url" "$label" "$NAME"
	else
		echo "Configured: ${label}"
	fi
fi

echo "Start"
for i in "${!RUNNER_DIRS[@]}"; do
	runner_dir="${RUNNER_DIRS[$i]}"
	label="${RUNNER_REPOS[$i]}"
	pid=$(start_runner "$runner_dir" "$label")
	echo "Started: ${label} (pid ${pid})"
	RUNNER_PIDS+=("$pid")
done

cleanup() {
	echo "Cleanup"

	if [ "$REMOVE_ON_EXIT" != "1" ]; then
		echo "Skip deregister"
		return
	fi

	for i in "${!RUNNER_DIRS[@]}"; do
		runner_dir="${RUNNER_DIRS[$i]}"
		repo="${RUNNER_REPOS[$i]}"

		cd "$runner_dir" || continue

		if [ -n "$REPOS" ]; then
			remove_token_url="https://api.github.com/repos/${repo}/actions/runners/remove-token"
			REMOVE_TOKEN=$(gh_token "$remove_token_url" || true)
			[ -n "$REMOVE_TOKEN" ] && ./config.sh remove --unattended --token "$REMOVE_TOKEN"
			continue
		fi

		if [ -n "$PAT_TOKEN" ]; then
			REMOVE_TOKEN=$(gh_token "$remove_token_url" || true)
			[ -n "$REMOVE_TOKEN" ] && ./config.sh remove --unattended --token "$REMOVE_TOKEN"
		else
			[ -n "$REG_TOKEN" ] && ./config.sh remove --unattended --token "$REG_TOKEN"
		fi
	done
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

for pid in "${RUNNER_PIDS[@]}"; do
	wait "$pid"
done
