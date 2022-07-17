#!/usr/bin/env bash

# The child program to execute
CHILD="alacritty"

#--------------------------------------------------------------------
# Some terminals require XDG be properly setup. We create a new
# set of XDG directories for this.
export XDG_BASE_DIR="/work/xdg"
export XDG_RUNTIME_DIR="${XDG_BASE_DIR}/runtime"
mkdir -p ${XDG_BASE_DIR} ${XDG_RUNTIME_DIR}
chmod 0700 $XDG_RUNTIME_DIR

#--------------------------------------------------------------------

# Start up the program under test
CHILD_LOG="${XDG_BASE_DIR}/child.log"
${CHILD} -o "window.start_maximized=true" >${CHILD_LOG} 2>&1 &
CHILD_PID=$!
echo "Child pid: ${CHILD_PID}"
echo "Child log: ${CHILD_LOG}"

sleep 2

xdotool type "/colors.sh"
xdotool key Return

sleep 1

import -window root /src/screen.jpeg
