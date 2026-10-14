#include "HeatGuardNative.h"

#include <limits.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>

// The public thread-info record exposes the effective priority but does not
// publish a portable Darwin-background enum.  On supported macOS releases a
// taskpolicy background thread has a low effective/max priority while the
// ordinary utility QoS reports policy 0.  Keep the probe conservative: require
// both low priorities and a non-zero scheduler policy, rather than treating
// every max-priority-4 utility task as already backgrounded.

static pthread_once_t hg_timebase_once = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t hg_timebase;

static void hg_initialize_timebase(void) {
    if (mach_timebase_info(&hg_timebase) != KERN_SUCCESS || hg_timebase.denom == 0) {
        hg_timebase.numer = hg_timebase.denom = 1;
    }
}

static uint64_t hg_nanoseconds(uint64_t absolute_time) {
    pthread_once(&hg_timebase_once, hg_initialize_timebase);
    __uint128_t scaled = (__uint128_t)absolute_time * hg_timebase.numer / hg_timebase.denom;
    return scaled > UINT64_MAX ? UINT64_MAX : (uint64_t)scaled;
}

static uint64_t hg_start_marker(const struct proc_bsdinfo *bsd) {
    return bsd->pbi_start_tvsec * 1000000ULL + bsd->pbi_start_tvusec;
}

int32_t hg_read_process(int32_t pid, HGProcessSample *sample) {
    if (pid <= 0 || sample == NULL) return 0;
    memset(sample, 0, sizeof(*sample));
    struct proc_bsdinfo bsd = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) return 0;

    sample->pid = pid;
    sample->parent_pid = (int32_t)bsd.pbi_ppid;
    sample->process_status = bsd.pbi_status;
    sample->uid = bsd.pbi_uid;
    // Keep the same identity source when metrics are denied or become available.
    sample->process_start_abstime = hg_start_marker(&bsd);
    strlcpy(sample->name, bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm, sizeof(sample->name));
    proc_pidpath(pid, sample->path, (uint32_t)sizeof(sample->path));

    struct rusage_info_v4 usage = {0};
    // The SDK's historical rusage_info_t* signature expects the STRUCT BUFFER,
    // not the address of a pointer variable. The latter overwrites the stack.
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
        sample->metrics_available = HG_METRICS_CPU | HG_METRICS_WAKEUPS
            | HG_METRICS_DISK | HG_METRICS_RESIDENT;
        // XNU task_power_info exports Mach absolute units on Apple Silicon;
        // Intel has a 1:1 timebase. Convert both sources exactly once here.
        sample->user_time_ns = hg_nanoseconds(usage.ri_user_time);
        sample->system_time_ns = hg_nanoseconds(usage.ri_system_time);
        sample->interrupt_wakeups = usage.ri_interrupt_wkups;
        sample->package_idle_wakeups = usage.ri_pkg_idle_wkups;
        sample->disk_read_bytes = usage.ri_diskio_bytesread;
        sample->disk_write_bytes = usage.ri_diskio_byteswritten;
        sample->resident_bytes = usage.ri_resident_size;
    } else {
        // Availability differs by OS/process. Missing wakeup/IO stays missing.
        struct proc_taskinfo task = {0};
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            sample->metrics_available = HG_METRICS_CPU | HG_METRICS_RESIDENT;
            sample->user_time_ns = hg_nanoseconds(task.pti_total_user);
            sample->system_time_ns = hg_nanoseconds(task.pti_total_system);
            sample->resident_bytes = task.pti_resident_size;
        }
    }

    // Reject a PID reused between the separate kernel reads.
    struct proc_bsdinfo verified = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &verified, sizeof(verified)) != sizeof(verified)
        || hg_start_marker(&verified) != sample->process_start_abstime
        || verified.pbi_uid != sample->uid) return 0;
    return 1;
}

static pthread_mutex_t hg_pid_buffer_lock = PTHREAD_MUTEX_INITIALIZER;
static int32_t *hg_pid_buffer;
static int32_t hg_pid_capacity;

int32_t hg_collect_processes(HGProcessSample *samples, int32_t capacity) {
    if (samples == NULL || capacity <= 0 || capacity > INT_MAX / (int32_t)sizeof(int32_t)) return 0;
    pthread_mutex_lock(&hg_pid_buffer_lock);
    if (hg_pid_capacity < capacity) {
        int32_t *replacement = realloc(hg_pid_buffer, (size_t)capacity * sizeof(int32_t));
        if (replacement == NULL) {
            pthread_mutex_unlock(&hg_pid_buffer_lock);
            return 0;
        }
        hg_pid_buffer = replacement;
        hg_pid_capacity = capacity;
    }
    int32_t pid_count = proc_listallpids(hg_pid_buffer, capacity * (int32_t)sizeof(int32_t));
    int32_t scan_count = pid_count < capacity ? pid_count : capacity;
    int32_t output_count = 0;
    for (int32_t index = 0; index < scan_count; index++) {
        HGProcessSample sample;
        if (hg_read_process(hg_pid_buffer[index], &sample)) samples[output_count++] = sample;
    }
    pthread_mutex_unlock(&hg_pid_buffer_lock);
    return output_count;
}

int32_t hg_read_self_footprint(uint64_t *bytes) {
    if (bytes == NULL) return 0;
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return 0;
    *bytes = usage.ri_phys_footprint;
    return 1;
}

int32_t hg_read_process_scheduling(int32_t pid, HGProcessScheduling *scheduling) {
    if (pid <= 0 || scheduling == NULL) return 0;
    // Darwin background policy is a thread policy.  PROC_PIDTASKINFO exposes
    // only the task's ordinary priority, which may remain unchanged after
    // `taskpolicy -b`; inspect a bounded thread list instead.
    uint64_t thread_ids[2048] = {0};
    int32_t bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0,
                                 thread_ids, (int)sizeof(thread_ids));
    if (bytes <= 0) return 0;
    uint32_t count = (uint32_t)(bytes / (int32_t)sizeof(thread_ids[0]));
    if (count > (uint32_t)(sizeof(thread_ids) / sizeof(thread_ids[0]))) {
        count = (uint32_t)(sizeof(thread_ids) / sizeof(thread_ids[0]));
    }
    memset(scheduling, 0, sizeof(*scheduling));
    scheduling->thread_count = count;
    struct proc_threadinfo first = {0};
    uint32_t readable = 0;
    uint32_t background = 0;
    for (uint32_t index = 0; index < count; index++) {
        struct proc_threadinfo thread = {0};
        if (proc_pidinfo(pid, PROC_PIDTHREADINFO, thread_ids[index],
                         &thread, sizeof(thread)) != sizeof(thread)) continue;
        if (readable == 0) first = thread;
        readable += 1;
        if (thread.pth_policy != 0 && thread.pth_priority <= 4
            && thread.pth_maxpriority <= 4) {
            background += 1;
        }
    }
    if (readable == 0) return 0;
    scheduling->policy = first.pth_policy;
    scheduling->priority = first.pth_priority;
    scheduling->max_priority = first.pth_maxpriority;
    scheduling->readable_threads = readable;
    scheduling->background_threads = background;
    return 1;
}

int32_t hg_read_host_cpu_ticks(HGHostCPUTicks *ticks) {
    if (ticks == NULL) {
        return 0;
    }

    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics(
        host,
        HOST_CPU_LOAD_INFO,
        (host_info_t)&cpu,
        &count
    );
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) {
        return 0;
    }

    ticks->user = cpu.cpu_ticks[CPU_STATE_USER];
    ticks->system = cpu.cpu_ticks[CPU_STATE_SYSTEM];
    ticks->idle = cpu.cpu_ticks[CPU_STATE_IDLE];
    ticks->nice = cpu.cpu_ticks[CPU_STATE_NICE];
    return 1;
}

int32_t hg_read_load_average(double *one_minute) {
    if (one_minute == NULL) return 0;
    struct loadavg load = {0};
    size_t size = sizeof(load);
    if (sysctlbyname("vm.loadavg", &load, &size, NULL, 0) != 0
        || load.fscale == 0) return 0;
    *one_minute = (double)load.ldavg[0] / (double)load.fscale;
    return 1;
}
