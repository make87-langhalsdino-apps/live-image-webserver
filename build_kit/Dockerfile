FROM debian:bookworm-slim

ARG VIRTUAL_ENV=/make87/venv

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      gnupg

RUN echo "deb http://archive.raspberrypi.org/debian/ bookworm main" > /etc/apt/sources.list.d/raspi.list \
    && apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 82B129927FA3303E


RUN apt-get update \
    && apt-get install --no-install-suggests --no-install-recommends -y \
        build-essential \
        python3-pip \
        python3 \
        libpython3-dev \
        python3-venv \
        python3-picamera2 \
        libcamera-apps \
        libcamera-dev \
        libcamera-tools \
        i2c-tools \
        python3-smbus \
        libcap-dev \
        python3-libcamera \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv ${VIRTUAL_ENV} --system-site-packages \
    && ${VIRTUAL_ENV}/bin/pip install -U \
      pip \
      setuptools \
      wheel

WORKDIR /app

COPY . .

RUN ${VIRTUAL_ENV}/bin/python3 -m pip install -U pip \
    && ${VIRTUAL_ENV}/bin/python3 -m pip install .

ENTRYPOINT ["/make87/venv/bin/python3", "-m", "app.main"]