#!/usr/bin/env bash
#
# This script runs a given test case and captures a screenshot. This script
# expects to run in the Docker image so it just captures the full screen rather
# than a specific window.
#
# This script also compares the output to the expected value. The expected
# value is the case file with ".png" appended. If the "--update" flag is
# appended, the test case is updated.

#--------------------------------------------------------------------
# Helpers

function has_func() {
    declare -f -F $1 > /dev/null
    return $?
}

#--------------------------------------------------------------------
# Flag parsing

ARG_UPDATE=0
ARG_OUT="/tmp/test.png"
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -e|--exec) ARG_EXEC="$2"; shift ;;
        -c|--case) ARG_CASE="$2"; shift ;;
        -o|--output) ARG_OUT="$2"; shift ;;
        -u|--update) ARG_UPDATE=1 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# If we're updating, then just update the file in-place
GOLDEN_OUT="${ARG_CASE}.${ARG_EXEC}.png"
if [ "$ARG_UPDATE" -eq 1 ]; then ARG_OUT=$GOLDEN_OUT; fi

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

if [ "$ARG_EXEC" = "ghostty" ]; then
  ARG_EXEC="/src/ghostty";
fi

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

echo "Comparing results..."
DIFF=$(compare -metric AE ${ARG_OUT} ${GOLDEN_OUT} null: 2>&1)
if [ $? -eq 2 ] ; then
  echo "  Comparison failed (error)"
  exit 1
else
  echo "  Diff: ${DIFF}"
  if [ $DIFF -gt 0 ]; then
    echo "  Diff is too high. Failure."
    exit 1
  fi
fi

echo "Done"
