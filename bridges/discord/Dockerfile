# mautrix-discord (the bridgev2 rewrite, branch megadiscord) plus
# Switchboard's per-channel bridging: upstream bridges a server whole or not
# at all, and the app's Settings choose channels one by one.
# patches/ holds the small edits to upstream files, overlay/ the new files.
# The branch has no tags yet, so it is pinned by commit. For a newer one,
# bump MAUTRIX_DISCORD_COMMIT and check the patches apply.
ARG MAUTRIX_DISCORD_COMMIT=c915e0345ccb3dc58a68f230cffb47e8540a702f

FROM alpine:3.24 AS source
ARG MAUTRIX_DISCORD_COMMIT
RUN apk add --no-cache git
RUN git init -q /src \
    && git -C /src remote add origin https://github.com/mautrix/discord \
    && git -C /src fetch -q --depth 1 origin ${MAUTRIX_DISCORD_COMMIT} \
    && git -C /src checkout -q FETCH_HEAD
WORKDIR /src
COPY patches/ /patches/
RUN git apply /patches/*.patch
COPY overlay/ /src/

# From here on, upstream's Dockerfile at the same commit, except that it
# builds with build.sh: the plain `go build` there finds no package.
# build.sh takes no flags here: it puts its arguments after the package
# path, where go reads them as more packages, so the binary is left in
# /build and copied from there.
FROM golang:1-alpine3.24 AS builder
RUN apk add --no-cache git ca-certificates build-base su-exec olm-dev
COPY --from=source /src /build
WORKDIR /build
RUN go test ./pkg/connector/ -run Switchboard
RUN ./build.sh

FROM alpine:3.24
ENV UID=1337 \
    GID=1337
RUN apk add --no-cache ffmpeg su-exec ca-certificates olm bash jq curl yq-go lottieconverter
COPY --from=builder /build/mautrix-discord /usr/bin/mautrix-discord
COPY --from=builder /build/docker-run.sh /docker-run.sh
VOLUME /data
CMD ["/docker-run.sh"]
