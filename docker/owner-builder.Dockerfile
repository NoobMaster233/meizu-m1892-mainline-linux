# SPDX-License-Identifier: MIT
FROM alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

ARG M1892_RELEASE_TAG=2026.09-developer-preview.17
ENV M1892_RELEASE_TAG=$M1892_RELEASE_TAG

RUN apk add --no-cache \
      alpine-sdk android-tools coreutils curl \
      e2fsprogs=1.47.4-r0 e2fsprogs-extra=1.47.4-r0 \
      findutils git gzip kmod openssh-client python3 su-exec tar unzip util-linux zstd zerofree \
 && test "$(e2fsck -V 2>&1 | awk 'NR==1 {print $2}')" = 1.47.4 \
 && adduser -D -h /home/m1892-builder -u 1000 m1892-builder

ENV M1892_CONTAINER_BUILD_USER=m1892-builder \
    M1892_CONTAINER_BUILD_HOME=/home/m1892-builder

COPY . /opt/m1892
WORKDIR /work
ENTRYPOINT ["/opt/m1892/scripts/build-owner-bundle.sh"]
