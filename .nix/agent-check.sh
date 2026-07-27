#!/usr/bin/env bash
set -euo pipefail

export CI="${CI:-1}"
export NO_COLOR="${NO_COLOR:-1}"
export FLUTTER_SUPPRESS_ANALYTICS="${FLUTTER_SUPPRESS_ANALYTICS:-true}"
export DART_SUPPRESS_ANALYTICS="${DART_SUPPRESS_ANALYTICS:-true}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

cache_root="${NIX_AGENT_CACHE_ROOT:-$repo_root/.cache/nix-agent}"
export PUB_CACHE="${PUB_CACHE:-$cache_root/dart-pub}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$cache_root/gradle}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_root/xdg-cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$cache_root/xdg-config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$cache_root/xdg-data}"
mkdir -p \
	"$PUB_CACHE" \
	"$GRADLE_USER_HOME" \
	"$XDG_CACHE_HOME" \
	"$XDG_CONFIG_HOME" \
	"$XDG_DATA_HOME"

git diff --check
nixfmt --check flake.nix .nix/devshell.nix
shellcheck .nix/agent-check.sh
shfmt -d .nix/agent-check.sh
actionlint .github/workflows/ci.yml .github/workflows/nix.yml
nix flake check --show-trace

expected_flutter_version="3.44.2"
actual_flutter_version="$(flutter --version --machine | jq -r '.frameworkVersion')"
if [ "$actual_flutter_version" != "$expected_flutter_version" ]; then
	printf 'expected Flutter %s from the Nix lock, found %s\n' \
		"$expected_flutter_version" \
		"$actual_flutter_version" >&2
	exit 1
fi

flutter --version
dart --version
flutter pub get
flutter analyze --no-fatal-infos
flutter test
