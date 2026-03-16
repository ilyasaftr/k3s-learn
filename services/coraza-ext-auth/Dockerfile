FROM golang:1.25-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/coraza-ext-auth ./cmd/coraza-ext-auth

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/coraza-ext-auth /usr/local/bin/coraza-ext-auth

EXPOSE 9002 9090
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/coraza-ext-auth"]
