#!/bin/bash

# =============================================================================
# build_wheel_and_upload.sh - Build the Mooncake wheel and upload it to OSS
#
# Builds only the builder stage of docker/mooncake.Dockerfile, extracts the
# produced wheel, and uploads it to OSS under a per-build date directory.
#
# The wheel version is stamped with the short commit id by the Dockerfile
# (MOONCAKE_WHEEL_VERSION_SUFFIX), so each build is identifiable by commit.
#
# Usage:
#   ./scripts/build_wheel_and_upload.sh
#   SKIP_UPLOAD=1 ./scripts/build_wheel_and_upload.sh    # build + extract only
#   PYTHON_VERSION=3.10 ./scripts/build_wheel_and_upload.sh
#
# Env vars (all optional, shown with defaults):
#   CUDA_VERSION     12.9.1      CUDA toolkit base tag.
#   UBUNTU_VERSION   22.04       Ubuntu base.
#   PYTHON_VERSION   3.11        Installed via deadsnakes PPA (major.minor).
#   BUILD_WITH_EP    0           1 enables -DWITH_EP=ON, 0 disables it.
#   DOCKERFILE       docker/mooncake.Dockerfile
#   BUILDKIT         1           Set to 0 to disable BuildKit.
#   OUTPUT_DIR       dist        Local directory to extract the wheel into.
#   SKIP_UPLOAD      0           1 = build + extract only, skip OSS upload.
#   OSSUTIL          /root/ossutil-2.1.2-linux-amd64/ossutil
#                                 Path to the ossutil binary.
#
# OSS destination (fixed): oss://siliconllm/llm-static/whl/mooncake-zwx-debug/
# The last path segment is the upload timestamp in MMDDHHMM format (e.g. 07161305).
#
# Prerequisites:
#   - git submodules populated: git submodule update --init extern/pybind11
#     extern/yalantinglibs  (the Dockerfile COPY . needs them)
#   - base image available locally or pullable:
#       nvidia/cuda:<CUDA_VERSION>-devel-ubuntu<UBUNTU_VERSION>
#   - ossutil installed at OSSUTIL path (unless SKIP_UPLOAD=1)
# =============================================================================

set -e
set -o pipefail

# Resolve repo root so the script can be run from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ---- Build args (env-overridable) -------------------------------------------
CUDA_VERSION="${CUDA_VERSION:-12.9.1}"
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
BUILD_WITH_EP="${BUILD_WITH_EP:-0}"
DOCKERFILE="${DOCKERFILE:-docker/mooncake.Dockerfile}"
BUILDKIT="${BUILDKIT:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
OSSUTIL="${OSSUTIL:-/root/ossutil-2.1.2-linux-amd64/ossutil}"

# Fixed OSS destination prefix; only the final date segment is dynamic.
OSS_PREFIX="oss://siliconllm/llm-static/whl/mooncake-zwx-debug"

export DOCKER_BUILDKIT="${BUILDKIT}"

SHORT_COMMIT="$(git rev-parse --short HEAD)"

# Builder image is only used to extract the wheel; tag is not published.
BUILDER_IMAGE="mooncake-build:wheel-${SHORT_COMMIT}"

echo "=== Mooncake wheel build + upload ==="
echo "  repo:       ${REPO_ROOT}"
echo "  branch:     $(git branch --show-current 2>/dev/null || echo detached)"
echo "  commit:     ${SHORT_COMMIT}"
echo "  dockerfile: ${DOCKERFILE}"
echo "  build args: CUDA=${CUDA_VERSION} UBUNTU=${UBUNTU_VERSION} PYTHON=${PYTHON_VERSION} EP=${BUILD_WITH_EP}"
echo "  builder:    ${BUILDER_IMAGE}"
echo "  output:     ${OUTPUT_DIR}/"
[ "${SKIP_UPLOAD}" = "1" ] && echo "  upload:     SKIPPED" || echo "  oss prefix: ${OSS_PREFIX}/<MMDDHHMM>/"
echo

# Quick guard: submodules must be populated (COPY . /workspace needs them).
for sub in extern/pybind11 extern/yalantinglibs; do
    if [ ! -f "${sub}/CMakeLists.txt" ]; then
        echo "ERROR: ${sub} not populated. Run:" >&2
        echo "  git submodule update --init ${sub}" >&2
        exit 1
    fi
done

# ---- 1. Build the builder stage (produces the wheel inside the image) --------
docker build \
    --target builder \
    --build-arg CUDA_VERSION="${CUDA_VERSION}" \
    --build-arg UBUNTU_VERSION="${UBUNTU_VERSION}" \
    --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
    --build-arg BUILD_WITH_EP="${BUILD_WITH_EP}" \
    -t "${BUILDER_IMAGE}" \
    -f "${DOCKERFILE}" \
    .

# ---- 2. Extract the wheel from the builder image ----------------------------
EXTRACT_CONTAINER="tmp-wheel-extract-${SHORT_COMMIT}"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
docker rm -f "${EXTRACT_CONTAINER}" >/dev/null 2>&1 || true
docker create --name "${EXTRACT_CONTAINER}" "${BUILDER_IMAGE}" >/dev/null
docker cp "${EXTRACT_CONTAINER}:/workspace/mooncake-wheel/dist/." "${OUTPUT_DIR}/"
docker rm "${EXTRACT_CONTAINER}" >/dev/null

WHEEL="$(ls "${OUTPUT_DIR}"/mooncake_transfer_engine-*.whl 2>/dev/null | head -1)"
if [ -z "${WHEEL}" ]; then
    echo "ERROR: no wheel found in ${OUTPUT_DIR}/ after extraction." >&2
    exit 1
fi
WHEEL_NAME="$(basename "${WHEEL}")"
WHEEL_SIZE="$(du -h "${WHEEL}" | cut -f1)"

echo
echo "=== Wheel built ==="
echo "  file:  ${WHEEL_NAME}"
echo "  size:  ${WHEEL_SIZE}"
echo "  path:  ${WHEEL}"

# ---- 3. Upload to OSS (unless SKIP_UPLOAD=1) --------------------------------
if [ "${SKIP_UPLOAD}" = "1" ]; then
    echo
    echo "=== Upload skipped (SKIP_UPLOAD=1) ==="
    exit 0
fi

if [ ! -x "${OSSUTIL}" ]; then
    echo "ERROR: ossutil not found or not executable at: ${OSSUTIL}" >&2
    echo "  Set OSSUTIL=<path> or install ossutil." >&2
    exit 1
fi

OSS_DATE_DIR="$(date '+%m%d%H%M')"
OSS_TARGET="${OSS_PREFIX}/${OSS_DATE_DIR}/"

echo
echo "=== Uploading to OSS ==="
echo "  target: ${OSS_TARGET}"
"${OSSUTIL}" cp "${WHEEL}" "${OSS_TARGET}" -f

echo
echo "=== Done ==="
echo "  wheel:   ${WHEEL_NAME} (${WHEEL_SIZE})"
echo "  oss url: ${OSS_TARGET}${WHEEL_NAME}"
