FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags=-s -o /hub ./cmd/hub

FROM alpine:3.22
COPY --from=build /hub /hub
USER 65534:65534
EXPOSE 8090
ENTRYPOINT ["/hub"]
