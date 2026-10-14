/*
 * Read-only, bounded resource measurement for the installed HeatGuard app.
 *
 * This program deliberately has no control surface: it never sends a signal,
 * changes task policy, changes priority, or writes to the app's state. The
 * target is bound to both its PID and kernel start markers before the first
 * sample; every later sample re-checks those markers and the executable path.
 * A PID reuse or path change terminates the measurement immediately.
 */

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

/* Keep this a HeatGuard-specific diagnostic, not a general process profiler. */
static const char kDefaultTargetPath[] =
    "/Applications/温衡.app/Contents/MacOS/HeatGuard";
static const char *gTargetPath = kDefaultTargetPath;

static volatile sig_atomic_t gStopRequested = 0;
static mach_timebase_info_data_t gTimebase;

struct Snapshot {
    int32_t pid;
    uint64_t start_marker_usec;
    uint64_t rusage_start_abstime;
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t footprint_bytes;
    uint64_t lifetime_max_footprint_bytes;
    char path[PATH_MAX];
};

static void request_stop(int signal_number) {
    (void)signal_number;
    gStopRequested = 1;
}

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) return -1.0;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int initialize_timebase(void) {
    if (mach_timebase_info(&gTimebase) != KERN_SUCCESS || gTimebase.denom == 0U)
        return 0;
    return 1;
}

static uint64_t mach_ticks_to_nanoseconds(uint64_t ticks) {
    __uint128_t scaled = (__uint128_t)ticks * gTimebase.numer / gTimebase.denom;
    return scaled > UINT64_MAX ? UINT64_MAX : (uint64_t)scaled;
}

static int read_snapshot(int32_t pid, struct Snapshot *snapshot) {
    if (snapshot == NULL || pid <= 1) return 0;
    memset(snapshot, 0, sizeof(*snapshot));

    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) !=
        (int)sizeof(bsd)) return 0;

    char path[PATH_MAX];
    memset(path, 0, sizeof(path));
    int path_length = proc_pidpath(pid, path, (uint32_t)sizeof(path));
    if (path_length <= 0 || path_length >= (int)sizeof(path) ||
        strcmp(path, gTargetPath) != 0) return 0;

    struct rusage_info_v4 usage;
    memset(&usage, 0, sizeof(usage));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return 0;

    snapshot->pid = pid;
    snapshot->start_marker_usec = bsd.pbi_start_tvsec * UINT64_C(1000000) +
        bsd.pbi_start_tvusec;
    snapshot->rusage_start_abstime = usage.ri_proc_start_abstime;
    /* proc_pid_rusage reports CPU times in Mach absolute units. Convert once
     * at the boundary so all deltas and percentages use real nanoseconds. */
    snapshot->user_time_ns = mach_ticks_to_nanoseconds(usage.ri_user_time);
    snapshot->system_time_ns = mach_ticks_to_nanoseconds(usage.ri_system_time);
    snapshot->footprint_bytes = usage.ri_phys_footprint;
    snapshot->lifetime_max_footprint_bytes = usage.ri_lifetime_max_phys_footprint;
    memcpy(snapshot->path, path, (size_t)path_length + 1U);
    return 1;
}

static int same_identity(const struct Snapshot *expected,
                         const struct Snapshot *observed) {
    return expected != NULL && observed != NULL &&
        expected->pid == observed->pid &&
        expected->start_marker_usec == observed->start_marker_usec &&
        expected->rusage_start_abstime == observed->rusage_start_abstime &&
        strcmp(observed->path, gTargetPath) == 0;
}

static uint64_t cpu_total_ns(const struct Snapshot *snapshot) {
    if (snapshot == NULL || UINT64_MAX - snapshot->user_time_ns <
        snapshot->system_time_ns) return 0;
    return snapshot->user_time_ns + snapshot->system_time_ns;
}

static uint64_t nonnegative_delta(uint64_t later, uint64_t earlier) {
    return later >= earlier ? later - earlier : 0;
}

static int is_delayed_interval(double elapsed, uint64_t interval) {
    return elapsed > (double)interval * 1.5 + 1.0;
}

static int sleep_until(double deadline) {
    for (;;) {
        if (gStopRequested) return 0;
        double now = monotonic_seconds();
        if (now < 0.0) return 0;
        double remaining = deadline - now;
        if (remaining <= 0.0) return 1;

        struct timespec pause;
        pause.tv_sec = (time_t)remaining;
        pause.tv_nsec = (long)((remaining - (double)pause.tv_sec) * 1e9);
        if (pause.tv_nsec < 0L) pause.tv_nsec = 0L;
        if (nanosleep(&pause, NULL) == 0) continue;
        if (errno != EINTR) return 0;
    }
}

static int parse_positive(const char *text, uint64_t *value) {
    if (text == NULL || value == NULL || *text == '\0') return 0;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed == 0ULL ||
        parsed > UINT64_MAX) return 0;
    *value = (uint64_t)parsed;
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "Usage: MeasureIdle PID DURATION_SECONDS INTERVAL_SECONDS [HeatGuard executable path]\n");
        fprintf(stderr, "Default target: %s\n", kDefaultTargetPath);
        return 2;
    }

    if (argc == 5) {
        const char *candidate = argv[4];
        const char *basename = strrchr(candidate, '/');
        if (candidate[0] != '/' || basename == NULL || strcmp(basename + 1, "HeatGuard") != 0 ||
            strlen(candidate) >= PATH_MAX) {
            fprintf(stderr, "Invalid target path; it must be an absolute HeatGuard executable path.\n");
            return 2;
        }
        gTargetPath = candidate;
    }

    uint64_t pid_value = 0;
    uint64_t duration = 0;
    uint64_t interval = 0;
    if (!parse_positive(argv[1], &pid_value) || pid_value > INT32_MAX ||
        !parse_positive(argv[2], &duration) || duration > 86400U ||
        !parse_positive(argv[3], &interval) || interval > 10U) {
        fprintf(stderr, "Invalid bounds (duration 1..86400s, interval 1..10s).\n");
        return 2;
    }
    int32_t pid = (int32_t)pid_value;

    if (!initialize_timebase()) {
        fprintf(stderr, "Unable to read Mach timebase; measurement stopped.\n");
        return 4;
    }

    (void)signal(SIGINT, request_stop);
    (void)signal(SIGTERM, request_stop);

    struct Snapshot identity;
    if (!read_snapshot(pid, &identity)) {
        fprintf(stderr, "Refused: PID %d is not the requested HeatGuard executable.\n", pid);
        return 3;
    }

    double start = monotonic_seconds();
    if (start < 0.0) {
        fprintf(stderr, "Unable to read monotonic clock.\n");
        return 4;
    }
    uint64_t initial_cpu_ns = cpu_total_ns(&identity);
    uint64_t previous_cpu_ns = initial_cpu_ns;
    double previous_sample_time = start;
    struct Snapshot last = identity;
    uint64_t sampled_peak_footprint = identity.footprint_bytes;
    uint64_t lifetime_peak_footprint = identity.lifetime_max_footprint_bytes;
    uint64_t samples = 1;
    uint64_t delayed_intervals = 0;
    double maximum_gap_seconds = 0.0;

    printf("measurement=started target_path=%s pid=%" PRId32
           " start_marker_usec=%" PRIu64
           " rusage_start_abstime=%" PRIu64
           " duration_limit_seconds=%" PRIu64
           " interval_seconds=%" PRIu64 "\n",
           gTargetPath, pid, identity.start_marker_usec,
           identity.rusage_start_abstime, duration, interval);
    printf("sample=0 elapsed_seconds=0.000 cpu_single_core_percent=0.000"
           " footprint_current_mib=%.3f footprint_sampled_peak_mib=%.3f"
           " footprint_lifetime_peak_mib=%.3f\n",
           (double)identity.footprint_bytes / 1048576.0,
           (double)sampled_peak_footprint / 1048576.0,
           (double)lifetime_peak_footprint / 1048576.0);
    fflush(stdout);

    double deadline = start + (double)duration;
    for (;;) {
        double now = monotonic_seconds();
        if (now < 0.0) {
            fprintf(stderr, "Monotonic clock failed; measurement stopped.\n");
            return 4;
        }
        double remaining = deadline - now;
        if (remaining <= 0.0) break;
        double next = now + (double)interval;
        if (next > deadline) next = deadline;
        if (!sleep_until(next)) break;
        if (gStopRequested) break;

        struct Snapshot observed;
        if (!read_snapshot(pid, &observed) || !same_identity(&identity, &observed)) {
            fprintf(stderr,
                    "Target changed or disappeared; measurement stopped without switching PID.\n");
            return 3;
        }
        now = monotonic_seconds();
        if (now < start) {
            fprintf(stderr, "Monotonic clock moved backwards; measurement stopped.\n");
            return 4;
        }
        uint64_t observed_cpu_ns = cpu_total_ns(&observed);
        uint64_t cpu_delta_ns = observed_cpu_ns >= previous_cpu_ns ?
            observed_cpu_ns - previous_cpu_ns : 0;
        double elapsed = now - start;
        double wall_delta = now - previous_sample_time;
        if (wall_delta <= 0.0) wall_delta = 1e-9;
        if (wall_delta > maximum_gap_seconds) maximum_gap_seconds = wall_delta;
        /* A gap may be sleep, scheduling delay or suspension. Do not guess
         * the cause, prevent it from silently passing an awake idle budget. */
        if (is_delayed_interval(wall_delta, interval)) delayed_intervals++;
        if (observed.footprint_bytes > sampled_peak_footprint)
            sampled_peak_footprint = observed.footprint_bytes;
        if (observed.lifetime_max_footprint_bytes > lifetime_peak_footprint)
            lifetime_peak_footprint = observed.lifetime_max_footprint_bytes;
        samples++;
        printf("sample=%" PRIu64 " elapsed_seconds=%.3f"
               " cpu_single_core_percent=%.3f"
               " cpu_cumulative_seconds=%.6f cpu_average_since_start_percent=%.3f"
               " footprint_current_mib=%.3f footprint_sampled_peak_mib=%.3f"
               " footprint_lifetime_peak_mib=%.3f\n",
               samples - 1U, elapsed,
               ((double)cpu_delta_ns / 1e9) / wall_delta * 100.0,
               (double)nonnegative_delta(observed_cpu_ns, initial_cpu_ns) / 1e9,
               elapsed > 0.0 ? ((double)nonnegative_delta(observed_cpu_ns, initial_cpu_ns) / 1e9) / elapsed * 100.0 : 0.0,
               (double)observed.footprint_bytes / 1048576.0,
               (double)sampled_peak_footprint / 1048576.0,
               (double)lifetime_peak_footprint / 1048576.0);
        fflush(stdout);
        previous_cpu_ns = observed_cpu_ns;
        previous_sample_time = now;
        last = observed;
    }

    double finish = monotonic_seconds();
    if (finish < start) finish = start;
    /* CPU counters belong to the last verified sample, not the later instant
     * when a signal interrupted sleep. Use the same window for the quotient. */
    double runtime = previous_sample_time - start;
    uint64_t user_delta_ns = nonnegative_delta(last.user_time_ns,
                                               identity.user_time_ns);
    uint64_t system_delta_ns = nonnegative_delta(last.system_time_ns,
                                                 identity.system_time_ns);
    uint64_t delta_cpu_ns = user_delta_ns;
    if (UINT64_MAX - delta_cpu_ns >= system_delta_ns)
        delta_cpu_ns += system_delta_ns;
    double average = runtime > 0.0 ? ((double)delta_cpu_ns / 1e9) /
        runtime * 100.0 : 0.0;
    printf("measurement=%s samples=%" PRIu64 " runtime_seconds=%.3f"
           " wall_runtime_seconds=%.3f"
           " continuous_window=%s delayed_intervals=%" PRIu64
           " maximum_gap_seconds=%.3f"
           " cpu_user_seconds=%.6f cpu_system_seconds=%.6f"
           " cpu_total_seconds=%.6f average_single_core_cpu_percent=%.3f"
           " footprint_current_mib=%.3f footprint_sampled_peak_mib=%.3f"
           " footprint_lifetime_peak_mib=%.3f\n",
           gStopRequested ? "interrupted" : "finished", samples, runtime,
           finish - start, delayed_intervals == 0 && !gStopRequested ? "yes" : "no",
           delayed_intervals, maximum_gap_seconds, (double)user_delta_ns / 1e9,
           (double)system_delta_ns / 1e9, (double)delta_cpu_ns / 1e9, average,
           (double)last.footprint_bytes / 1048576.0,
           (double)sampled_peak_footprint / 1048576.0,
           (double)lifetime_peak_footprint / 1048576.0);
    if (gStopRequested) return 130;
    if (delayed_intervals > 0) return 6;
    return 0;
}
