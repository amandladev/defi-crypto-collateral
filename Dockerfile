FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /api ./cmd/api
RUN CGO_ENABLED=0 GOOS=linux go build -o /liquidator ./cmd/liquidator

FROM alpine:3.19
RUN apk --no-cache add ca-certificates
WORKDIR /app

COPY --from=builder /api /app/api
COPY --from=builder /liquidator /app/liquidator

EXPOSE 8080
CMD ["/app/api"]
