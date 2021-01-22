# Builder image
FROM golang:1.13-buster as builder

# ARG XENON_TAG v1.1.3
RUN set -ex; \
    mkdir -p /go/src/github.com/radondb; \
    cd /go/src/github.com/radondb; \
    # git clone --branch $XENON_TAG https://github.com/radondb/xenon.git
    git clone https://github.com/radondb/xenon.git; \
    cd xenon; \
    make build


FROM ubuntu:focal

RUN set -ex; \
    groupadd -r mysql && useradd -r -g mysql mysql; \
    echo 'mysql':'mysql' | chpasswd; \
    apt-get update; \
    if ! which gpg; then \
        apt-get install -y --no-install-recommends gnupg; \
    fi; \
    if ! gpg --version | grep -q '^gpg (GnuPG) 1\.'; then \
        apt-get install -y --no-install-recommends dirmngr; \
    fi; \
    apt-get install -y --no-install-recommends openssh-server sshpass supervisor; \
    mkdir -p /var/run/sshd; \
    rm -rf /etc/supervisor/*; \
    echo "mysql  ALL=(ALL:ALL) ALL" >> /etc/sudoers; \
    echo "mysql  ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers; \
    rm -rf /var/lib/apt/lists/*

ARG XTRABACKUP_PKG=percona-xtrabackup-24
RUN set -ex; \
    key='9334A25F8507EFA5'; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keys.gnupg.net --recv-keys "$key"; \
    gpg --batch --export $key > /etc/apt/trusted.gpg.d/mysql.gpg; \
    command -v gpgconf > /dev/null && gpgconf --kill all || :; \
    rm -r "$GNUPGHOME"; \
    apt-key list > /dev/null; \
    echo "deb http://repo.percona.com/apt focal main\ndeb-src http://repo.percona.com/apt focal main">> /etc/apt/sources.list.d/mysql.list; \
    apt-get update; \
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true; \
    { \
        echo percona-server-server-5.7 percona-server-server-5.7/root-pass password ''; \
        echo percona-server-server-5.7 percona-server-server-5.7/re-root-pass password ''; \
        echo tzdata tzdata/Areas select Asia; \
        echo tzdata tzdata/Zones/Asia select Shanghai; \
    } | debconf-set-selections; \
    # install "pwgen" for randomizing passwords
    # install "tzdata" for /usr/share/zoneinfo/
    # install "xz-utils" for .sql.xz docker-entrypoint-initdb.d files
    apt-get install -y --no-install-recommends libjemalloc1 libmecab2 pwgen tzdata xz-utils; \
    apt-get install -y --no-install-recommends \
        percona-server-server-5.7 \
        percona-server-common-5.7 \
        percona-server-tokudb-5.7 \
        percona-toolkit \
        ${XTRABACKUP_PKG}; \
    # TokuDB modifications
    echo "LD_PRELOAD=/usr/lib64/libjemalloc.so.1" >> /etc/default/mysql; \
    echo "THP_SETTING=never" >> /etc/default/mysql; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/lib/mysql /etc/alternatives/my.cnf /etc/mysql/*; \
    mkdir -p /xenon /etc/xenon /var/log/xenon /var/lib/xenon /var/lib/mysql /var/log/mysql /var/run/mysqld /docker-entrypoint-initdb.d; \
    echo "/etc/xenon/xenon.json" > /xenon/config.path; \
    # allow to change config files
    chown -R mysql:mysql /xenon /etc/xenon /var/log/xenon /var/lib/xenon /var/lib/mysql /var/log/mysql /var/run/mysqld /etc/mysql; \
    # ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
    chmod 1777 /var/run/mysqld

VOLUME ["/var/lib/xenon", "/var/log/xenon", "/var/lib/mysql", "/var/log/mysql"]

COPY --from=builder /go/src/github.com/radondb/xenon/bin/xenon /xenon/xenon
COPY --from=builder /go/src/github.com/radondb/xenon/bin/xenoncli /xenon/xenoncli
COPY xenon-entry.sh /docker-entrypoint.sh
COPY --chown=mysql:mysql my.cnf /etc/mysql/my.cnf
COPY supervisord.conf /etc/supervisor/supervisord.conf

EXPOSE 3306
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n"]
