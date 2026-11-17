FROM --platform=$BUILDPLATFORM golang:1.27.4-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /yieldd-coordinator . \
    && mkdir -p -m 0700 /state/yieldd

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /yieldd-coordinator /yieldd-coordinator
COPY --from=build --chown=65532:65532 /state/ /var/lib/
USER 65532:65532
ENTRYPOINT ["/yieldd-coordinator"]
