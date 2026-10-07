FROM golang:1.26.6-bookworm AS build
WORKDIR /repo
COPY packages/go/ packages/go/
COPY services/wire-corpus-edge/go.mod services/wire-corpus-edge/go.sum services/wire-corpus-edge/
WORKDIR /repo/services/wire-corpus-edge
RUN go mod download
COPY services/wire-corpus-edge/cmd/ cmd/
COPY services/wire-corpus-edge/internal/ internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /wire-corpus-edge ./cmd/wire-corpus-edge
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /wire-corpus-edge /wire-corpus-edge
EXPOSE 8080
ENTRYPOINT ["/wire-corpus-edge"]
