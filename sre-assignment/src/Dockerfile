FROM ubuntu:latest

ARG TARGETARCH

WORKDIR /src

RUN apt-get update && apt-get install -y \
    wget \
    curl \
    git \
    build-essential \
    ca-certificates \
    net-tools \
    iputils-ping \
    dnsutils \
    htop \
    procps \
    gcc \
    make \
    python3 \
    python3-pip \
    nano

RUN wget https://go.dev/dl/go1.26.2.linux-${TARGETARCH}.tar.gz && \
    tar -C /usr/local -xzf go1.26.2.linux-${TARGETARCH}.tar.gz && \
    rm go1.26.2.linux-${TARGETARCH}.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/root/go"
ENV CGO_ENABLED=1

COPY . .

RUN go build -gcflags "all=-N -l" -ldflags "-compressdwarf=false" -o /app .

ENV APP_ENV=development
ENV DEBUG=true
ENV LOG_LEVEL=debug

EXPOSE 8080
EXPOSE 22
EXPOSE 9090

ENTRYPOINT ["/app"]
