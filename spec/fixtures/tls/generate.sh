#!/usr/bin/env sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

rm -f \
  "$DIR/ca.key" "$DIR/ca.crt" \
  "$DIR/server.key" "$DIR/server.csr" "$DIR/server.crt" \
  "$DIR/client.key" "$DIR/client.csr" "$DIR/client.crt" \
  "$DIR/ca.srl"

cat > "$TMPDIR/server-ext.cnf" <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
EOF

cat > "$TMPDIR/client-ext.cnf" <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out "$DIR/ca.key" 2048
openssl req -x509 -new -nodes -key "$DIR/ca.key" -sha256 -days 3650 \
  -subj "/CN=grpc-e2e-ca" \
  -out "$DIR/ca.crt"

openssl genrsa -out "$DIR/server.key" 2048
openssl req -new -key "$DIR/server.key" \
  -subj "/CN=localhost" \
  -out "$DIR/server.csr"
openssl x509 -req -in "$DIR/server.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$DIR/server.crt" -days 3650 -sha256 \
  -extfile "$TMPDIR/server-ext.cnf"

openssl genrsa -out "$DIR/client.key" 2048
openssl req -new -key "$DIR/client.key" \
  -subj "/CN=grpc-e2e-client" \
  -out "$DIR/client.csr"
openssl x509 -req -in "$DIR/client.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$DIR/client.crt" -days 3650 -sha256 \
  -extfile "$TMPDIR/client-ext.cnf"

rm -f "$DIR/server.csr" "$DIR/client.csr" "$DIR/ca.srl"