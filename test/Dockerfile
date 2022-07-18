#--------------------------------------------------------------------
# vttest
#--------------------------------------------------------------------
FROM alpine:3.16 AS vttest

RUN apk add --no-cache build-base curl

RUN curl -o vttest.tar.gz https://invisible-island.net/archives/vttest/vttest-20220215.tgz && \
    tar xvzf vttest.tar.gz && \
    cd vttest-20220215 && \
    ./configure && \
    make && \
    cp ./vttest /

#--------------------------------------------------------------------
# main runner
#--------------------------------------------------------------------
FROM alpine:3.16

# Base packages. A good set of this is just to get X (xvfb) and OpenGL
# software rendering working (all the mesa drivers).
RUN apk add --no-cache \
    bash \
    grep \
    procps \
    font-inconsolata-nerd \
    i3wm \
    imagemagick \
    libxrandr \
    mesa-dev \
    mesa-dri-gallium \
    mesa-gl \
    xvfb \
    xvfb-run \
    xdotool

# Our terminals
RUN apk add --no-cache \
    alacritty \
    xterm

COPY --from=vttest /vttest /usr/bin/vttest

COPY ./run.sh /entrypoint.sh

ENTRYPOINT ["/bin/bash"]
