#!/bin/bash

# =============================================================================
# build_docker_image.sh - Build the Mooncake runtime Docker image
#
# Builds docker/mooncake.Dockerfile (multi-stage: builder + runtime) and tags
# the resulting image as mooncake:<git-describe>-<pyShort>-<cuShort>:
#   - git-describe is `git describe --tags --always` (e.g. v0.3.12-pre2).
#   - pyShort/cuShort encode the Python and CUDA versions (e.g. py311, cu128).
#
# The build stamps the wheel version with the commit id + CUDA version via
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
#   PIP_INDEX_URL    https://pypi.org/simple
#                                 PyPI index for get-pip.py (setuptools/wheel).
#                                 Use a mirror on restricted networks, e.g.
#                                 https://pypi.tuna.tsinghua.edu.cn/simple
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
# PyPI index used by get-pip.py (builder) and pip install (runtime) to fetch
# setuptools/wheel and the wheel's Python deps. pypi.org is unreachable on some
# restricted networks; point this at a mirror, e.g.
# PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.org/simple}"

export DOCKER_BUILDKIT="${BUILDKIT}"

# ---- Compute image tag from git describe --tags ----------------------------
# Uses the full `git describe --tags --always` output verbatim as the image
# tag, keeping the `v` prefix and `-` separators for readability and
# traceability (e.g. v0.3.12-pre1-61-gce65dd58).
# The wheel version uses the same source as a local version suffix (via
# MOONCAKE_WHEEL_VERSION_SUFFIX in the Dockerfile), with `-` replaced by
# `.` to satisfy PEP 440 local-segment constraints, preserving `pre1`
# verbatim (PEP 440 does not normalize local segments).
PY_SHORT="py$(echo ${PYTHON_VERSION} | tr -d .)"
CU_SHORT="cu$(echo ${CUDA_VERSION} | cut -d. -f1-2 | tr -d .)"
IMAGE_TAG="$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)-${PY_SHORT}-${CU_SHORT}"
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
    --build-arg PIP_INDEX_URL="${PIP_INDEX_URL}" \
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
    # --gpus all is required: libcuda.so.1 is provided by the host NVIDIA driver,
    # not bundled in the CUDA runtime image.  The compat dir LD_LIBRARY_PATH
    # mirrors the CUDA major.minor from CUDA_VERSION (e.g. cuda-13.2).
    CUDA_COMPAT="/usr/local/cuda-${CUDA_VERSION%.*}"
    if docker run --rm --gpus all --entrypoint /bin/bash "${IMAGE_REF}" -c "
            export LD_LIBRARY_PATH=${CUDA_COMPAT}/compat:\${LD_LIBRARY_PATH:-}
            /usr/bin/python -c 'import mooncake; from mooncake.engine import TransferEngine; from mooncake.store import MooncakeDistributedStore; print(\"import OK\")'
        "; then
        echo "Smoke test passed."
    else
        echo "WARNING: smoke test failed (image is still built)." >&2
    fi
fi
