#!/usr/bin/env bash
# Creates the k3d cluster, builds both images, imports them, and starts the Geode server.
# Safe to re-run: reuses the cluster and the downloaded tarball, rebuilds and re-imports images.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER=geode-repro
CTX="k3d-${CLUSTER}"
GEODE_VERSION=1.15.1
TGZ="${ROOT}/geode-server/apache-geode-${GEODE_VERSION}.tgz"
URL="https://archive.apache.org/dist/geode/${GEODE_VERSION}/apache-geode-${GEODE_VERSION}.tgz"

if k3d cluster get "${CLUSTER}" >/dev/null 2>&1; then
  echo "== k3d cluster ${CLUSTER} already exists"
else
  echo "== Creating k3d cluster ${CLUSTER}"
  k3d cluster create "${CLUSTER}" --wait
fi

echo "== Building client jar"
(cd "${ROOT}/app" && mvn -q -DskipTests package)

if [[ ! -f "${TGZ}" ]]; then
  echo "== Downloading Apache Geode ${GEODE_VERSION}"
  curl -fL --retry 3 -o "${TGZ}.part" "${URL}"
  curl -fsL --retry 3 -o "${TGZ}.sha256" "${URL}.sha256"
  # Drop the file name, keep only the hex digest (handles "hash  file" and "file: AB CD" formats).
  expected="$(sed 's/apache-geode[^ ]*//' "${TGZ}.sha256" | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f')"
  actual="$(shasum -a 256 "${TGZ}.part" | awk '{print $1}')"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "sha256 mismatch: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
  mv "${TGZ}.part" "${TGZ}"
fi

echo "== Building images"
docker build -q -t repro-client:dev "${ROOT}/app"
docker build -q --build-arg GEODE_VERSION="${GEODE_VERSION}" -t "geode-server:${GEODE_VERSION}" "${ROOT}/geode-server"

echo "== Importing images into ${CLUSTER}"
k3d image import -c "${CLUSTER}" repro-client:dev "geode-server:${GEODE_VERSION}"

echo "== Starting Geode locator + server"
kubectl --context "${CTX}" apply -f "${ROOT}/k8s/geode.yaml"
kubectl --context "${CTX}" rollout status deploy/geode --timeout=300s

echo "== Ready. Next: scripts/run.sh <broken|fixed> <delete|liveness|close-cache>"
