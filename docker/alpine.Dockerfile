# Alpine (musl) build environment for a fully static rascal: make STATIC=full
FROM alpine:3.22
RUN apk add --no-cache build-base linux-headers curl patch
