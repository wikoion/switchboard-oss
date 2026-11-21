# mautrix-slack plus Switchboard's per-channel bridging: upstream bridges
# every channel or, with dm_only, none, and the app's Settings choose
# channels one by one on top of dm_only (set in deploy/overlays/slack.yaml).
# patches/ holds the small edits to upstream files, overlay/ the new files.
# For a new release, bump MAUTRIX_SLACK_TAG and check the patches apply.
ARG MAUTRIX_SLACK_TAG=v0.2610.0

FROM alpine:3.24 AS source
ARG MAUTRIX_SLACK_TAG
RUN apk add --no-cache git
RUN git clone --depth 1 --branch ${MAUTRIX_SLACK_TAG} https://github.com/mautrix/slack /src
WORKDIR /src
COPY patches/ /patches/
RUN git apply /patches/*.patch
COPY overlay/ /src/

# From here on, upstream's Dockerfile at the same tag.
FROM golang:1-alpine3.24 AS builder
RUN apk add --no-cache git ca-certificates build-base su-exec olm-dev
COPY --from=source /src /build
WORKDIR /build
RUN go test ./pkg/connector/ -run Switchboard
RUN ./build.sh

FROM alpine:3.24
ENV UID=1337 \
    GID=1337
RUN apk add --no-cache ffmpeg su-exec ca-certificates olm bash jq yq-go curl
COPY --from=builder /build/mautrix-slack /usr/bin/mautrix-slack
COPY --from=builder /build/docker-run.sh /docker-run.sh
VOLUME /data
CMD ["/docker-run.sh"]
