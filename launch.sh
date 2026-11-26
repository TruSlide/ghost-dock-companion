#!/bin/zsh
# Start Ghost (or restart it after a rebuild).
cd "${0:A:h}"
pkill -x Ghost 2>/dev/null; sleep 0.5
open "$PWD/Ghost.app"
