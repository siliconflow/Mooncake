#!/bin/bash

# =============================================================================
# build_docker_image.sh - Build the Mooncake runtime Docker image
#
# Builds docker/mooncake.Dockerfile (multi-stage: builder + runtime) and tags
# the resulting image as mooncake:<latest-tag>[-<short-commit>]:
#   - If HEAD is exactly on the latest git tag, the tag is that tag
#     (e.g. v0.3.12-pre2).
#   - Otherwise the short commit id is appended (e.g. v0.3.12-pre2-3bc2e88e).
#
# The build stamps the wheel version with the short commit id via
# MOONCAKE_WHEEL_VERSION_SUFFIX (see scripts/build_wheel.sh).
#
# Usage:
#   ./scripts/build_docker_image.sh
#   CUDA_VERSION=12.9.1 UBUNTU_VERSION=22.04 PYTHON_VERSION=3.11 \
#     BUILD_WITH_EP=0 IMAGE_NAME=mooncake ./scripts/build_docker_image.sh
#
# Env vars (all optional, shown with defaults):
#   CUDA_VERSION     12.9.1      CUDA toolkit base tag.
#   UBUNTU_VERSION   22.04       Ubuntu base.
#   PYTHON_VERSION   3.11        Installed via deadsnakes PPA (major.minor).
#   BUILD_WITH_EP    0           1 enables -DWITH_EP=ON, 0 disables it.
#   IMAGE_NAME       mooncake    Repository name for the produced image.
#   DOCKERFILE       docker/mooncake.Dockerfile
#   BUILDKIT         1           Set to 0 to disable BuildKit.
#
# Prerequisites:
#   - git submodules populated: git submodule update --init extern/pybind11
#     extern/yalantinglibs  (the Dockerfile COPY . needs them)
#   - base images available locally or pullable:
#       nvidia/cuda:<CUDA_VERSION>-devel-ubuntu<UBUNTU_VERSION>
#       nvidia/cuda:<CUDA_VERSION>-runtime-ubuntu<UBUNTU_VERSION>
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
IMAGE_NAME="${IMAGE_NAME:-mooncake}"
DOCKERFILE="${DOCKERFILE:-docker/mooncake.Dockerfile}"
BUILDKIT="${BUILDKIT:-1}"

export DOCKER_BUILDKIT="${BUILDKIT}"

# ---- Compute image tag from git describe --tags ----------------------------
# Uses the full `git describe --tags --always` output verbatim as the image
# tag, keeping the `v` prefix and `-` separators for readability and
# traceability (e.g. v0.3.12-pre1-61-gce65dd58).
# The wheel version uses the same source as a local version suffix (via
# MOONCAKE_WHEEL_VERSION_SUFFIX in the Dockerfile), with `-` replaced by
# `.` to satisfy PEP 440 local-segment constraints, preserving `pre1`
# verbatim (PEP 440 does not normalize local segments).
IMAGE_TAG="$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)"
SHORT_COMMIT="$(git rev-parse --short HEAD)"

IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=== Mooncake Docker image build ==="
echo "  repo:       ${REPO_ROOT}"
echo "  branch:     $(git branch --show-current 2>/dev/null || echo detached)"
echo "  commit:     ${SHORT_COMMIT}"
echo "  describe:   ${IMAGE_TAG}"
echo "  dockerfile: ${DOCKERFILE}"
echo "  build args: CUDA=${CUDA_VERSION} UBUNTU=${UBUNTU_VERSION} PYTHON=${PYTHON_VERSION} EP=${BUILD_WITH_EP}"
echo "  image:      ${IMAGE_REF}"
echo

# Quick guard: submodules must be populated (COPY . /workspace needs them).
for sub in extern/pybind11 extern/yalantinglibs; do
    if [ ! -f "${sub}/CMakeLists.txt" ]; then
        echo "ERROR: ${sub} not populated. Run:" >&2
        echo "  git submodule update --init ${sub}" >&2
        exit 1
    fi
done

docker build \
    --build-arg CUDA_VERSION="${CUDA_VERSION}" \
    --build-arg UBUNTU_VERSION="${UBUNTU_VERSION}" \
    --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
    --build-arg BUILD_WITH_EP="${BUILD_WITH_EP}" \
    -t "${IMAGE_REF}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "=== Build complete ==="
echo "Image: ${IMAGE_REF}"
echo "Size:  $(docker images "${IMAGE_REF}" --format '{{.Size}}')"

# Optional import smoke test (guarded so it doesn't mask a successful build).
if [ "${SKIP_SMOKE_TEST:-0}" != "1" ]; then
    echo "=== Smoke test: import mooncake ==="
    if docker run --rm --entrypoint /bin/bash "${IMAGE_REF}" -c '
            export LD_LIBRARY_PATH=/usr/local/cuda-12.9/compat:${LD_LIBRARY_PATH:-}
            /usr/bin/python -c "import mooncake; from mooncake.engine import TransferEngine; from mooncake.store import MooncakeDistributedStore; print(\"import OK\")"
        '; then
        echo "Smoke test passed."
    else
        echo "WARNING: smoke test failed (image is still built)." >&2
    fi
fi
