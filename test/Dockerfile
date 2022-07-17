FROM alpine:3.16

# Base packages. A good set of this is just to get X (xvfb) and OpenGL
# software rendering working (all the mesa drivers).
RUN apk add --no-cache \
    bash \
    grep \
    procps \
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
    alacritty

COPY ./run.sh /run.sh
COPY ./colors.sh /colors.sh

ENTRYPOINT ["/bin/bash"]
