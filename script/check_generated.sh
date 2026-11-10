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

for fixture in spec/fixtures/generator/collisions.proto spec/interop/peer.proto \
  spec/protobuf_options/large.proto vendor/grpc-proto/grpc/health/v1/health.proto; do
  output=$(dirname "$fixture")
  proto_root=$(dirname "$fixture")
  proto_source=$(basename "$fixture")
  format_output="$output"
  if [[ "$fixture" == vendor/grpc-proto/* ]]; then
    proto_root=vendor/grpc-proto
    proto_source=${fixture#vendor/grpc-proto/}
    output=src
    format_output=src/grpc/health/v1
  fi
  if [[ "$fixture" == spec/interop/* ]]; then
    output=spec/interop/generated
    format_output="$output"
    protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
      --crystal_out="$output" google/protobuf/wrappers.proto
  fi
  protoc -I "$proto_root" \
    --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
    --plugin=protoc-gen-crystal-grpc=bin/protoc-gen-crystal-grpc \
    --crystal_out="$output" --crystal-grpc_out="$output" "$proto_source"
  crystal tool format "$format_output"
done

if [[ "${1:-}" == --write ]]; then exit 0; fi
git diff --exit-code HEAD -- spec/fixtures/generator spec/interop/generated spec/protobuf_options src/grpc/health/v1
test -z "$(git ls-files --others --exclude-standard spec/fixtures/generator spec/interop/generated spec/protobuf_options src/grpc/health/v1)"
