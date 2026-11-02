#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---check}" in
  --check|--write) ;;
  *) echo "Usage: $0 [--check|--write]" >&2; exit 2 ;;
esac

mkdir -p bin spec/interop/generated
crystal build lib/proto/src/protoc-gen-crystal_main.cr -o bin/protoc-gen-crystal
crystal build src/protoc-gen-crystal-grpc_main.cr -o bin/protoc-gen-crystal-grpc

for fixture in spec/fixtures/generator/collisions.proto spec/interop/peer.proto; do
  output=$(dirname "$fixture")
  if [[ "$fixture" == spec/interop/* ]]; then
    output=spec/interop/generated
    protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
      --crystal_out="$output" google/protobuf/wrappers.proto
  fi
  protoc -I "$(dirname "$fixture")" \
    --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
    --plugin=protoc-gen-crystal-grpc=bin/protoc-gen-crystal-grpc \
    --crystal_out="$output" --crystal-grpc_out="$output" "$(basename "$fixture")"
  crystal tool format "$output"
done

if [[ "${1:-}" == --write ]]; then exit 0; fi
git diff --exit-code HEAD -- spec/fixtures/generator spec/interop/generated
test -z "$(git ls-files --others --exclude-standard spec/fixtures/generator spec/interop/generated)"
