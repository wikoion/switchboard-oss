FROM golang:1-alpine AS builder
RUN apk add --no-cache git ca-certificates build-base
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# goolm: the pure-Go olm, so the image needs no libolm.
RUN go build -tags goolm -ldflags "-s -w" -o /sb-matrix ./cmd/sb-matrix

FROM alpine:3.23
ENV UID=1337 \
    GID=1337
RUN apk add --no-cache su-exec ca-certificates bash
COPY --from=builder /sb-matrix /usr/bin/sb-matrix
COPY docker-run.sh /docker-run.sh
VOLUME /data
CMD ["/docker-run.sh"]
