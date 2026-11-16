#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=7.27.0
sha256=db9c4b738727698748746144394cb7ee96512fe50166555baaeeca9311ee1dba
jar="${OPENAPI_GENERATOR_JAR:-$PWD/.cache/openapi-generator-cli-$version.jar}"

if [[ ! -f "$jar" && -n "${OPENAPI_GENERATOR_JAR:-}" ]]; then
    printf 'OpenAPI Generator JAR not found at %s\n' "$jar" >&2
    exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
if [[ ! -f "$jar" ]]; then
    mkdir -p .cache
    artifact="openapi-generator-cli-$version.jar"
    curl --fail --silent --show-error --location --retry 3 \
        "https://repo.maven.apache.org/maven2/org/openapitools/openapi-generator-cli/$version/$artifact" \
        --output "$scratch/$artifact"
    printf '%s  %s\n' "$sha256" "$scratch/$artifact" | shasum -a 256 --check --status
    mv "$scratch/$artifact" "$jar"
fi

if ! printf '%s  %s\n' "$sha256" "$jar" | shasum -a 256 --check --status; then
    printf 'OpenAPI Generator JAR checksum mismatch: %s\n' "$jar" >&2
    exit 1
fi

java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}java"
actual_version="$("$java_bin" -jar "$jar" version)"
if [[ "$actual_version" != "$version" ]]; then
    printf 'Expected OpenAPI Generator %s, got %s\n' "$version" "$actual_version" >&2
    exit 1
fi

python3 scripts/prepare-generation.py spec/vertesia-openapi.json "$jar" "$scratch"
if ! "$java_bin" -jar "$jar" generate \
    -c openapi-generator-config.yaml \
    -i "$scratch/openapi.json" \
    -t "$scratch/templates" \
    -o "$scratch/output" >"$scratch/generate.log" 2>&1; then
    tail -80 "$scratch/generate.log" >&2
    exit 1
fi

sources="$scratch/output/Sources/VertesiaClient"
python3 scripts/postprocess.py "$sources" "$scratch/openapi.json"
test -f "$sources/Infrastructure/APIs.swift"
if [[ "${1:-}" == "--check" ]]; then
    diff -ru Sources/VertesiaClient/Generated "$sources"
else
    rm -rf Sources/VertesiaClient/Generated
    mv "$sources" Sources/VertesiaClient/Generated
fi
