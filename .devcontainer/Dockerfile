# kamui-isa development image.
# Everything a contributor needs to build and check Kamui (no GPU required):
# clang 20 (NVPTX + RISC-V), the CUDA 12.8 toolkit for ptxas/nvdisasm/cuobjdump,
# the RISC-V GNU toolchain, Spike + pk, Sail, herdtools7, Alloy, Dartagnan,
# CMake/Ninja/g++-14, and a Python 3.12 venv for tools/.
# Versions are pinned here and documented in docs/tools/devcontainer.md.

ARG CUDA_IMAGE=nvidia/cuda:12.8.1-devel-ubuntu24.04

# ---------------------------------------------------------------- Spike + pk
FROM ${CUDA_IMAGE} AS spike
ARG SPIKE_COMMIT=4c6a9bc79dab80616932949707e7c0471d8e9e54
ARG PK_COMMIT=9c61d29846d8521d9487a57739330f9682d5b542
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates device-tree-compiler libboost-regex-dev \
      libboost-system-dev gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
      picolibc-riscv64-unknown-elf \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/riscv-software-src/riscv-isa-sim /src/spike \
    && git -C /src/spike checkout ${SPIKE_COMMIT} \
    && git -C /src/spike submodule update --init --depth 1 berkeley-softfloat-3 \
    && mkdir /src/spike/build && cd /src/spike/build \
    && ../configure --prefix=/opt/riscv && make -j"$(nproc)" && make install
RUN git clone https://github.com/riscv-software-src/riscv-pk /src/pk \
    && git -C /src/pk checkout ${PK_COMMIT} \
    && mkdir /src/pk/build && cd /src/pk/build \
    && ../configure --prefix=/opt/riscv --host=riscv64-unknown-elf --with-arch=rv64imafd_zicsr_zifencei \
         CC="riscv64-unknown-elf-gcc --specs=picolibc.specs" \
    && make -j"$(nproc)" && make install

# ---------------------------------------------------------------- Dartagnan
FROM ${CUDA_IMAGE} AS dat3m
ARG DAT3M_TAG=4.4.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates openjdk-17-jdk-headless maven \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 -b ${DAT3M_TAG} https://github.com/hernanponcedeleon/Dat3M /opt/dat3m \
    && cd /opt/dat3m && mvn -q -B clean install -DskipTests \
    && rm -rf /root/.m2 /opt/dat3m/.git

# ---------------------------------------------------------------- final image
FROM ${CUDA_IMAGE}
ARG LLVM_VERSION=20
ARG SAIL_VERSION=0.20.3
ARG ALLOY_VERSION=6.2.0
ARG HERDTOOLS_VERSION=7.58
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++-14 cmake ninja-build git curl wget ca-certificates gnupg \
      lsb-release software-properties-common sudo less vim-tiny file xz-utils unzip \
      pkg-config libgmp-dev zlib1g-dev z3 libz3-dev m4 \
      opam ocaml ocaml-findlib \
      device-tree-compiler libboost-regex1.83.0 libboost-system1.83.0 \
      gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf picolibc-riscv64-unknown-elf gdb-multiarch \
      openjdk-17-jdk-headless \
      python3 python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

# LLVM 20 from apt.llvm.org (clang with the NVPTX and RISC-V targets).
RUN curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-${LLVM_VERSION} main" \
       > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       clang-${LLVM_VERSION} lld-${LLVM_VERSION} llvm-${LLVM_VERSION} llvm-${LLVM_VERSION}-tools \
       clang-format-${LLVM_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# Sail: official binary release, as sail-riscv recommends.
RUN curl -fsSL https://github.com/rems-project/sail/releases/download/${SAIL_VERSION}-binary/sail-Linux-x86_64.tar.gz \
      | tar -xz -C /opt && mv /opt/sail* /opt/sail-tmp && mv /opt/sail-tmp /opt/sail \
    && /opt/sail/bin/sail --version

# herdtools7 (herd7, litmus7, diy7) through opam, using the system OCaml.
ENV OPAMROOT=/opt/opam OPAMYES=1
RUN opam init --disable-sandboxing --bare -n \
    && opam switch create default ocaml-system \
    && opam install herdtools7.${HERDTOOLS_VERSION} \
    && opam clean -a -c -s --logs \
    && chmod -R a+rX /opt/opam

# Alloy 6 (CLI and GUI jar).
RUN mkdir -p /opt/alloy \
    && curl -fsSL https://github.com/AlloyTools/org.alloytools.alloy/releases/download/v${ALLOY_VERSION}/alloy-${ALLOY_VERSION}-linux-amd64.tar.gz \
       | tar -xz -C /opt/alloy

COPY --from=spike /opt/riscv /opt/riscv
COPY --from=dat3m /opt/dat3m /opt/dat3m

# Python venv for the scripts in tools/.
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*

ENV CUDA_HOME=/usr/local/cuda \
    DAT3M_HOME=/opt/dat3m \
    DAT3M_OUTPUT=/tmp/dat3m-output \
    PATH=/opt/venv/bin:/opt/sail/bin:/opt/opam/default/bin:/opt/riscv/bin:/usr/lib/llvm-20/bin:/usr/local/cuda/bin:${PATH}

# Non-root user. The Ubuntu base image ships a "ubuntu" user at UID 1000; replace it.
RUN (userdel -r ubuntu 2>/dev/null || true) \
    && groupadd -g ${USER_GID} ${USERNAME} \
    && useradd -l -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}
USER ${USERNAME}
WORKDIR /workspaces/kamui-isa
# Drop the CUDA base image's banner entrypoint so tool output stays clean.
ENTRYPOINT []
CMD ["bash"]
