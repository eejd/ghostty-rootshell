#!/usr/bin/env bash
#
# This script runs a given test case and captures a screenshot. This script
# expects to run in the Docker image so it just captures the full screen rather
# than a specific window.
#
# This outputs the captured image to the `--output` value. This will not
# compare the captured output. This is only used to capture the output of
# a test case.

#--------------------------------------------------------------------
# Helpers

function has_func() {
    declare -f -F $1 > /dev/null
    return $?
}

#--------------------------------------------------------------------
# Flag parsing

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -e|--exec) ARG_EXEC="$2"; shift ;;
        -c|--case) ARG_CASE="$2"; shift ;;
        -o|--output) ARG_OUT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

bad=0
if [ -z "$ARG_EXEC" ]; then bad=1; fi
if [ -z "$ARG_CASE" ]; then bad=1; fi
if [ -z "$ARG_OUT" ]; then bad=1; fi
if [ $bad -ne 0 ]; then
  echo "Usage: run.sh --exec <terminal> --case <path to case> --output <path to png>"
  exit 1
fi

# Load our test case
source ${ARG_CASE}
if ! has_func "test_do"; then
  echo "Test case is invalid."
  exit 1
fi

echo "Term: ${ARG_EXEC}"
echo "Case: ${ARG_CASE}"

#--------------------------------------------------------------------
# Some terminals require XDG be properly setup. We create a new
# set of XDG directories for this.
export XDG_BASE_DIR="/work/xdg"
export XDG_RUNTIME_DIR="${XDG_BASE_DIR}/runtime"
mkdir -p ${XDG_BASE_DIR} ${XDG_RUNTIME_DIR}
chmod 0700 $XDG_RUNTIME_DIR

# Configure i3
cat <<EOF >${XDG_BASE_DIR}/i3.cfg
exec ${ARG_EXEC}
EOF

#--------------------------------------------------------------------

# Start up the program under test by launching i3. We use i3 so we can
# more carefully control the window settings, test resizing, etc.
WM_LOG="${XDG_BASE_DIR}/wm.log"
i3 -c ${XDG_BASE_DIR}/i3.cfg >${WM_LOG} 2>&1 &

echo
echo "Started window manager..."

# Wait for startup
# TODO: we can probably use xdotool or wmctrl or something to detect if any
# windows actually launched and make error handling here better.
sleep 2

# Run our test case (should be defined in test case file)
echo "Executing test case..."
test_do

# Sleep a second to let it render
sleep 1

echo "Capturing screen shot..."
import -window root ${ARG_OUT}

echo "Done"
