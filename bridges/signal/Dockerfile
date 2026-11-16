# mautrix-signal plus Switchboard's call signalling relay: the bridge passes
# Signal call messages to and from the app, which runs RingRTC itself.
# patches/ holds the small edits to upstream files, overlay/ the new files.
# For a new release, bump MAUTRIX_SIGNAL_TAG and check the patches apply.
ARG MAUTRIX_SIGNAL_TAG=v0.2610.0

FROM alpine:3.24 AS source
ARG MAUTRIX_SIGNAL_TAG
RUN apk add --no-cache git
RUN git clone --depth 1 --branch ${MAUTRIX_SIGNAL_TAG} --recurse-submodules --shallow-submodules \
    https://github.com/mautrix/signal /src
WORKDIR /src
COPY patches/ /patches/
RUN git apply /patches/*.patch
COPY overlay/ /src/

# From here on, upstream's Dockerfile at the same tag.
FROM rust:1-alpine AS rust-builder
RUN apk add --no-cache git make cmake protoc musl-dev g++ clang-dev protobuf-dev
WORKDIR /build
COPY --from=source /src/pkg/libsignalgo/libsignal/. pkg/libsignalgo/libsignal/.
COPY --from=source /src/build-rust.sh .
RUN ./build-rust.sh

FROM golang:1-alpine3.24 AS go-builder
RUN apk add --no-cache git ca-certificates build-base olm-dev zlib-dev
WORKDIR /build
COPY --from=source /src/ ./
ENV LIBRARY_PATH=.
COPY --from=rust-builder /build/pkg/libsignalgo/libsignal/target/*/libsignal_ffi.a ./
RUN go test ./pkg/signalcall/
RUN ./build-go.sh

FROM alpine:3.24
ENV UID=1337 \
    GID=1337
RUN apk add --no-cache ffmpeg su-exec ca-certificates bash jq curl yq-go olm
COPY --from=go-builder /build/mautrix-signal /usr/bin/mautrix-signal
COPY --from=go-builder /build/docker-run.sh /docker-run.sh
VOLUME /data
CMD ["/docker-run.sh"]
