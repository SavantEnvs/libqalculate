// mayhem/fuzz.cpp — libFuzzer harness for libqalculate's expression parser/evaluator.
//
// The valuable fuzz surface is the expression PARSER + EVALUATOR (numeric and symbolic). We feed the
// raw fuzz bytes straight in as an expression string.
//
// Two API/runtime concerns drive this harness:
//
//  1. THREADING. Calculator::calculate(MathStructure*, str, msecs, ...) (the void-pointer variant)
//     evaluates in a PERSISTENT WORKER THREAD and, on timeout, CANCELS it mid-flight, leaking the
//     thread's in-progress allocations. We instead use the MathStructure-returning
//     Calculator::calculate(str, eo, ...) variant, which evaluates ENTIRELY in the calling thread and
//     bounds its runtime via the global abort control (startControl(msecs) → aborted() polled during
//     evaluation). No worker thread to cancel.
//
//  2. PER-INPUT TIME BOUND (mandatory). Some expressions drive libqalculate's simplifier into very
//     long / effectively non-terminating evaluation (deep RootFunction / gcd simplification). Without
//     an in-harness bound, Mayhem's coverage-collection pass — which does not apply libFuzzer's
//     -timeout — HANGS forever on such an input and the run never leaves "Preparing Next Phase". So we
//     ALWAYS bound evaluation with startControl(kCalcMsecs).
//
//  3. ABORT LEAK (tolerated, build-time). When evaluation is aborted by the time bound,
//     libqalculate's replace_fracpow() (MathStructure-gcd.cc) skips its restore_fracpow() cleanup
//     and leaks a few small temporary UnknownVariables — a genuine UPSTREAM leak, not a harness
//     bug. We disable LeakSanitizer (only) at BUILD time via __lsan_is_turned_off() (§6.1 — a
//     runtime __asan_default_options override is forbidden; Mayhem alone owns the runtime ASAN/
//     LibFuzzer option set) so these known, bounded leaks don't swamp the run; ASan use-after-free/
//     overflow and UBSan stay FULLY ON and HALTING. The leaked memory is small and plateaus
//     (~hundreds of MB steady-state), so it does not OOM the fuzzer.
//
// The Calculator is expensive to construct (loads the bundled functions/units/variables definitions
// from the in-image data dir — no network), so it is built ONCE in a lazy file-scope singleton.
#include <libqalculate/Calculator.h>
#include <libqalculate/MathStructure.h>
#include <string>
#include <cstdint>
#include <cstddef>

namespace {

// Per-input wall budget for evaluation + printing. Small, so no single expression can wedge the
// fuzzer or Mayhem's coverage pass.
const int kCalcMsecs = 250;

Calculator *get_calculator() {
    // Constructing a Calculator sets the global CALCULATOR pointer as a side effect.
    static Calculator *calc = [] {
        Calculator *c = new Calculator();
        c->loadGlobalDefinitions();
        c->loadLocalDefinitions();
        return c;
    }();
    return calc;
}

} // namespace

// Disable LeakSanitizer only (see header note 3); keep memory-safety + UBSan halting.
extern "C" int __lsan_is_turned_off() {
    return 1;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // Cap input size — larger inputs add no parser coverage, only slow the fuzzer.
    if (size > 4096) return 0;

    Calculator *calc = get_calculator();
    std::string expr(reinterpret_cast<const char *>(data), size);

    EvaluationOptions eo;
    MathStructure parsed;

    // Bound runtime via the in-thread abort control, then parse + evaluate in THIS thread.
    calc->startControl(kCalcMsecs);
    MathStructure result = calc->calculate(expr, eo, &parsed);

    // Exercise the printer too (a large, separate code path that consumes the evaluated structure),
    // under the same abort control so a pathological print can't hang either.
    PrintOptions po;
    std::string out = calc->print(result, kCalcMsecs, po);
    (void) out;

    calc->stopControl();

    // result/parsed are stack MathStructures; their destructors release everything they own.
    return 0;
}
