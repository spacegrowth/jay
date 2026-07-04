#!/bin/bash
# Run Jay's logic test suites (Foundation-only — no app build, no AppKit).
# Used locally and by CI (.github/workflows/ci.yml). Exits non-zero if any suite fails.
set -uo pipefail
cd "$(dirname "$0")"   # app/

fail=0
run() {   # run <name> <output> <source files...>
  local name="$1" out="$2"; shift 2
  echo "▶ $name"
  if swiftc "$@" -o "$out" 2>&1 && "$out"; then :; else fail=1; echo "  (suite FAILED)"; fi
  echo
}

run "Contexts logic" /tmp/jay-ctxtests \
  Contexts/ContextKey.swift Contexts/ContextEngine.swift Contexts/ContextOverrides.swift \
  Contexts/ContextLabeler.swift Contexts/ContextStore.swift Tests/ContextTests.swift

run "Plugin host" /tmp/jay-phtests \
  Adapters/PluginHost.swift Tests/PluginHostTests.swift

[ "$fail" -eq 0 ] && echo "✅ all suites passed" || echo "❌ some suites failed"
exit $fail
