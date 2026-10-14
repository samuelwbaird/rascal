# Ubuntu (glibc) build environment: third party libraries static, glibc dynamic
FROM ubuntu:24.04
RUN apt-get update \
	&& apt-get install -y --no-install-recommends build-essential curl ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
