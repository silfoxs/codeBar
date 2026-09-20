#!/usr/bin/env bash
set -euo pipefail

SUBSYSTEM="${AI_USAGE_LOG_SUBSYSTEM:-com.silfoxs.codeBar}"
exec log stream --style compact --level debug --predicate "subsystem == '$SUBSYSTEM'"
