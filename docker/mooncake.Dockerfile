###############################################################################
# Stage 1: build Mooncake from source and produce a Python wheel
###############################################################################
ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=22.04

FROM dk.sc4.ai:10443/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

ARG PYTHON_VERSION=3.10
ARG PYPA_INDEX_URL=https://bootstrap.pypa.io
ARG PIP_INDEX_URL=https://pypi.org/simple
ARG CMAKE_BUILD_TYPE=Release
ARG EP_TORCH_VERSIONS="2.12.1"
ARG TORCH_CUDA_ARCH_LIST="8.9;9.0a;10.3;10.0a;12.0"

ARG BUILD_WITH_EP=0
ENV PYTHON_VERSION=${PYTHON_VERSION} \
    BUILD_WITH_EP=${BUILD_WITH_EP} \
    EP_TORCH_VERSIONS=${EP_TORCH_VERSIONS} \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    PATH="/usr/local/go/bin:${PATH}" \
    GOPROXY=https://goproxy.cn,direct \
    GOSUMDB=sum.golang.google.cn

# Install base build utilities and the requested Python version via deadsnakes PPA
# PIP_INDEX_URL lets get-pip.py fetch setuptools/wheel from a reachable mirror
# on restricted networks (e.g. --build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple).
RUN chmod 1777 /tmp && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        ninja-build \
        software-properties-common \
        pkg-config && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-venv && \
    curl -sS ${PYPA_INDEX_URL}/get-pip.py | PIP_INDEX_URL=${PIP_INDEX_URL} python${PYTHON_VERSION} && \
    update-alternatives --install /usr/bin/python  python  /usr/bin/python${PYTHON_VERSION} 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 && \
    apt-get purge -y --auto-remove software-properties-common && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace

# Install Mooncake dependencies (yalantinglibs, Go, etc.)
RUN bash dependencies.sh -y

# Configure & build Mooncake
RUN mkdir -p build && \
    cd build && \
    cmake -G Ninja .. \
        -DBUILD_UNIT_TESTS=OFF \
        -DUSE_HTTP=ON \
        -DUSE_ETCD=ON \
        -DUSE_CUDA=ON \
        -DWITH_EP=$( [ "$BUILD_WITH_EP" = "1" ] && echo ON || echo OFF ) \
        -DSTORE_USE_ETCD=ON \
        -DPython3_EXECUTABLE=/usr/bin/python${PYTHON_VERSION} \
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} && \
    export LIBRARY_PATH=/usr/local/cuda/lib64/stubs:$LIBRARY_PATH && \
    cmake --build .

# Build nvlink allocator to make wheel self-contained for CUDA paths
RUN export PATH=/usr/local/nvidia/bin:/usr/local/nvidia/lib64:$PATH && \
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:$LD_LIBRARY_PATH && \
    export LIBRARY_PATH=/usr/local/cuda/lib64/stubs:$LIBRARY_PATH && \
    mkdir -p build/mooncake-transfer-engine/nvlink-allocator && \
    cd mooncake-transfer-engine/nvlink-allocator && \
    bash build.sh ../../build/mooncake-transfer-engine/nvlink-allocator/

# Ubuntu 22.04's apt ships patchelf 0.14.3, but auditwheel requires >= 0.14.5.
# Upgrade via pip so the binary in PATH shadows the apt version.
# Placed here (not in dependencies.sh) so the expensive cmake/allocator layers
# above stay cached.
RUN python${PYTHON_VERSION} -m pip install patchelf>=0.14.5

# Build the Python wheel from local sources
# CUDA_VERSION is re-declared here (not at the top of the stage) so that adding
# it doesn't invalidate the Docker cache for the expensive apt-get / cmake layers above.
ARG CUDA_VERSION
RUN OUTPUT_DIR=dist \
    MOONCAKE_WHEEL_VERSION_SUFFIX="$(git describe --tags --always | sed 's/^v//; s/-/./g').cu$(echo ${CUDA_VERSION} | cut -d. -f1-2 | tr -d .)" \
    ./scripts/build_wheel.sh

###############################################################################
# Stage 2: export the built wheels to the host filesystem.
#
# Consumed by scripts/build_wheel_and_upload.sh via
#   docker build --target wheel-export --output type=local,dest=dist
# This streams the wheel out through BuildKit without running a container,
# which is required under rootless nerdctl where `cp` from a stopped container
# (docker create) is unsupported.
###############################################################################
FROM scratch AS wheel-export
COPY --from=builder /workspace/mooncake-wheel/dist/. /

###############################################################################
# Stage 3: install the freshly built wheel into a runtime image
###############################################################################
FROM dk.sc4.ai:10443/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Inherit build-args so the runtime stage installs the matching interpreter
ARG PYTHON_VERSION=3.10
ARG PYPA_INDEX_URL=https://bootstrap.pypa.io
ENV PYTHON_VERSION=${PYTHON_VERSION}

# Install runtime dependencies and the requested Python version
RUN chmod 1777 /tmp && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        software-properties-common \
        ibverbs-providers \
        rdma-core \
        libibverbs1 \
        librdmacm1 \
        libnuma1 \
        liburing2 \
        libyaml-0-2 \
        libcurl4 \
        libgflags2.2 \
        libunwind8 && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION} && \
    curl -sS ${PYPA_INDEX_URL}/get-pip.py | python${PYTHON_VERSION} && \
    update-alternatives --install /usr/bin/python  python  /usr/bin/python${PYTHON_VERSION} 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 && \
    apt-get purge -y --auto-remove software-properties-common curl && \
    rm -rf /var/lib/apt/lists/*

# Copy wheels produced in builder stage and install them via pip
COPY --from=builder /workspace/mooncake-wheel/dist /tmp/mooncake-wheel
COPY --chmod=755 scripts/check_hicache_hugepage_requirements.py /usr/local/bin/mooncake-hicache-sizing
# PyPI index for the wheel's runtime deps (aiohttp/requests/msgpack). Override
# with a reachable mirror on restricted networks, e.g.
#   --build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# Declared after the cached apt/get-pip layers so overriding only rebuilds this
# final install step (the expensive builder stage stays cached).
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN python${PYTHON_VERSION} -m pip install --no-cache-dir --index-url ${PIP_INDEX_URL} \
        /tmp/mooncake-wheel/*.whl && \
    rm -rf /tmp/mooncake-wheel /root/.cache/pip

CMD ["/bin/bash"]
