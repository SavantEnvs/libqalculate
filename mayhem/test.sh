#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libqalculate's OWN upstream test suite (built by build.sh) and emit CTRF.
#
# The suite is libqalculate's `qalc --test-file=<file>` known-answer-test mode driven over the
# upstream tests/*.batch files. Each .batch file is a list of `expression\n\tEXPECTED-RESULT` pairs;
# qalc parses+evaluates each expression with the REAL library and compares the printed result to the
# expected value, printing "<file> - <N> tests passed" on success and "Mismatch detected ... expected
# '<x>' received '<y>'" + exiting non-zero on the FIRST wrong value (src/qalc.cc unittest path).
#
# This is a genuine behavioral oracle on OUTPUT, not exit status: a program neutered to exit(0) — or
# any semantic mutation that returns wrong-but-non-crashing results — produces mismatches (or zero
# "tests passed" markers) and FAILS here. CTRF counts are PARSED from qalc's actual output (the
# "<N> tests passed" lines), never hardcoded.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

QALC="$SRC/build-tests/src/qalc"
if [ ! -x "$QALC" ]; then
  echo "qalc test runner not found at $QALC — build.sh did not build the oracle" >&2
  emit_ctrf "qalculate" 0 1
  exit 1
fi

# Definitions are needed at runtime (qalc loads functions/units/variables). Point at the staged dir.
export QALCULATE_DEFINITIONS_DIR="${QALCULATE_DEFINITIONS_DIR:-/mayhem/qalculate-data}"

shopt -s nullglob
BATCHES=( "$SRC"/tests/*.batch )
if [ "${#BATCHES[@]}" -eq 0 ]; then
  echo "no tests/*.batch files found" >&2
  emit_ctrf "qalculate" 0 1
  exit 1
fi

# Each .batch file = one suite. We count an asserted KAT pass per "<N> tests passed" qalc reports
# (summing N across all files = total individual value-assertions exercised) and a suite FAIL on any
# file where qalc reports a mismatch / exits non-zero / reports 0 tests.
total_pass=0
files_failed=0
files_ran=0
for f in "${BATCHES[@]}"; do
  files_ran=$(( files_ran + 1 ))
  out="$("$QALC" --test-file="$f" 2>&1)"; rc=$?
  # qalc prints e.g. "tests/parser.batch - 137 tests passed"
  n="$(printf '%s\n' "$out" | sed -n 's/.* - \([0-9][0-9]*\) tests passed.*/\1/p' | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
    total_pass=$(( total_pass + n ))
  else
    files_failed=$(( files_failed + 1 ))
    echo "FAIL: $(basename "$f") (rc=$rc)"
    printf '%s\n' "$out" | grep -i "mismatch\|expected\|received\|WARNING" | head -5
  fi
done

echo "ran $files_ran batch suites; $total_pass individual KAT assertions passed; $files_failed suite(s) failed"
if [ "$files_failed" -eq 0 ] && [ "$total_pass" -gt 0 ]; then
  emit_ctrf "qalculate-qalc-test-file" "$total_pass" 0
else
  # Report failures: if total_pass is 0 (e.g. neutered binary), force at least 1 failed.
  failed="$files_failed"; [ "$failed" -lt 1 ] && failed=1
  emit_ctrf "qalculate-qalc-test-file" "$total_pass" "$failed"
fi
