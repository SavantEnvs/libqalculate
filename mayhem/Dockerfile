# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds the libqalculate fuzz harness ON TOP of the org
# C/C++ base (clang/llvm + libFuzzer + the build-contract ENV + the `mayhem` identity).
#
# libqalculate is an autotools C++ project with external deps (GMP, MPFR, libxml2) plus the
# autotools/gettext toolchain. Those are pre-baked here so mayhem/build.sh re-runs fully OFFLINE.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t libqalculate-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Build deps for libqalculate's autotools build: GMP, MPFR, libxml2 (mandatory), plus the
# autoconf/automake/libtool/gettext/intltool toolchain (autogen.sh) and pkg-config. libcurl/icu are
# disabled in build.sh so they're intentionally NOT installed. Pinned to SOURCE_DATE_EPOCH (if set)
# for reproducibility, then the apt lists are dropped so the build layer stays air-gapped.
USER root
RUN { [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true; } ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libgmp-dev libmpfr-dev libxml2-dev \
        autoconf automake libtool pkg-config \
        gettext autopoint intltool \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (CI checkout); the FULL repo (incl. .git history) is copied to
# /mayhem and build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# The fuzz binary loads libqalculate's definitions at runtime; point it at the staged data dir baked
# by build.sh. Calculator::getGlobalDefinitionsDir() reads this env var.
ENV QALCULATE_DEFINITIONS_DIR=/mayhem/qalculate-data

# Run libqalculate's own test suite at build time (fails the image if the oracle fails).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
