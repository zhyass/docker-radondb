# Builder image
FROM golang:1.13-buster as builder

# ARG RADON_TAG=v1.1.3
RUN set -ex; \
    mkdir -p /go/src/github.com/radondb; \
    cd /go/src/github.com/radondb; \
    # git clone --branch $RADON_TAG https://github.com/radondb/radon.git
    git clone https://github.com/radondb/radon.git; \
    cd radon; \
    make build

FROM ubuntu:focal

ARG TZ="Asia/Shanghai"
RUN set -ex; \
    echo "$TZ" > /etc/localtime; \
    groupadd --gid 999 --system radon; \
    useradd \
    --uid 999 \
    --system \
    --home-dir /var/lib/radon \
    --no-create-home \
    --gid radon \
    radon; \
    mkdir /var/lib/radon /radon; \
    chown -R radon:radon /var/lib/radon /radon

COPY --from=builder --chown=radon:radon /go/src/github.com/radondb/radon/bin/radon /radon/radon
COPY radon-entry.sh /docker-entrypoint.sh
VOLUME /var/lib/radon

USER radon
EXPOSE 3306
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/radon/radon", "-c", "/radon/radon.json"]
