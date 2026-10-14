/* Pure diagnostic-helper checks: never reads or controls a running process. */
#define main measurement_program_main
#include "MeasureIdle.c"
#undef main

int main(void) {
    unsigned failures = 0;
    unsigned count = 0;
#define CHECK(value) do { count++; if (!(value)) { failures++; \
    fprintf(stderr, "FAIL measurement helper: %s\n", #value); } } while (0)
    CHECK(!is_delayed_interval(10.005, 10));
    CHECK(!is_delayed_interval(16.0, 10));
    CHECK(is_delayed_interval(16.001, 10));
    CHECK(is_delayed_interval(296.791, 10));
    CHECK(!is_delayed_interval(1.01, 1));
    CHECK(is_delayed_interval(2.501, 1));
    CHECK(nonnegative_delta(100, 20) == 80);
    CHECK(nonnegative_delta(20, 100) == 0);
    gTimebase.numer = 125;
    gTimebase.denom = 3;
    CHECK(mach_ticks_to_nanoseconds(3) == 125);
    CHECK(mach_ticks_to_nanoseconds(UINT64_MAX) == UINT64_MAX);
    struct Snapshot expected = {0};
    expected.pid = 44;
    expected.start_marker_usec = 100;
    expected.rusage_start_abstime = 200;
    strcpy(expected.path, kDefaultTargetPath);
    struct Snapshot actual = expected;
    CHECK(same_identity(&expected, &actual));
    actual.pid++;
    CHECK(!same_identity(&expected, &actual));
    actual = expected; actual.start_marker_usec++;
    CHECK(!same_identity(&expected, &actual));
    actual = expected; actual.rusage_start_abstime++;
    CHECK(!same_identity(&expected, &actual));
    actual = expected; strcpy(actual.path, "/tmp/not-heatguard");
    CHECK(!same_identity(&expected, &actual));
    CHECK(!same_identity(NULL, &actual));
    printf("Measurement helper tests: %u/%u passed\n", count - failures, count);
    return failures ? 1 : 0;
}
