FROM alpine as builder

WORKDIR /build
RUN apk add --no-cache build-base git curl-dev curl-static

RUN git clone https://github.com/jfhenriques/meocloud-upload.git . \
    && make

FROM bash:5

WORKDIR /app
COPY *.sh ./
COPY --from=builder /build/meocloud/meocloud /usr/bin/meocloud

ENV CONFIG_DIR=/app/config \
    STORE_DIR=/store \
    USE_DEFAULT_INCLUDE=/host \
    FAIL_CONFIG_NOT_EXISTS=0

RUN apk add --no-cache gawk pv pigz openssl tar libcurl libstdc++ tzdata findutils \
    && dos2unix /app/*.sh \
    && chmod +x /app/*.sh \
    && ln -sf /app/abackup.sh /usr/bin/abackup \
    && ln -sf /app/abackup_schedule.sh /usr/bin/abackup_schedule
