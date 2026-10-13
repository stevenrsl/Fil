#!/bin/zsh
# Lance les serveurs locaux, exécute les tests d'intégration, arrête les serveurs.
set -euo pipefail

ROOT="${0:A:h:h}"
STATE="${FIL_TEST_SERVERS:-${${TMPDIR:-/tmp}%/}/fil-test-servers}"
STATE="${STATE%/}"
export FIL_TEST_SERVERS="$STATE"

"$ROOT/Tools/test-servers.sh" start
trap '"$ROOT/Tools/test-servers.sh" stop' EXIT

set -a
source "$STATE/env"
set +a

cd "$ROOT"
swift test --filter IntegrationTests "$@"
