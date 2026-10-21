#syntax=docker/dockerfile:1
# Multi-stage build for a minimal, static, non-root image.
#
# Why not the skeleton's Dockerfile: it is based on ubuntu:latest, downloads the
# Go toolchain at build time, shipped ~20 debug packages (nano, htop, net-tools,
# python3...) and ran the app with CGO and full debug symbols enabled. A
# container should carry nothing that isn't needed at runtime.
#
# Runtime image: distroless/static (no shell, no package manager, ~2 MB +
# app binary). The app is a plain net/http server, so CGO is disabled and the
# static build has no libc requirement; gcr.io/distroless/static is safe.

# --- Build stage ------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build

WORKDIR /src

# go.mod first would enable layer caching for the deps download, but this
# project has zero dependencies (go.mod has no require block), so copy
# everything in one go and use BuildKit's cache mount instead.
COPY . .

# $TARGETOS/$TARGETARCH are BuildKit AutoFill ARGs. Building on an Apple
# Silicon host with Docker Desktop produces arm64 binaries matching the
# minikube (arm64) node.
ARG TARGETOS TARGETARCH

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/app .

# --- Runtime stage ----------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /

COPY --from=build /out/app /app

# Matches the `runAsUser`/`runAsNonRoot` set in deployment.yaml.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/app"]
