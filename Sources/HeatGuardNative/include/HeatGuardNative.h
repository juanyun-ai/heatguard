#ifndef HEAT_GUARD_NATIVE_H
#define HEAT_GUARD_NATIVE_H

#include <stdint.h>
#include <sys/types.h>

#define HG_PROCESS_NAME_LENGTH 64
#define HG_PROCESS_PATH_LENGTH 1024

enum {
    HG_METRICS_CPU = 1 << 0,
    HG_METRICS_WAKEUPS = 1 << 1,
    HG_METRICS_DISK = 1 << 2,
    HG_METRICS_RESIDENT = 1 << 3,
};

typedef struct {
    int32_t pid;
    int32_t parent_pid;
    uint32_t process_status; // BSD p_stat; SZOMB means exited, awaiting parent collection.
    uint32_t uid;
    uint8_t metrics_available; // HG_METRICS_* bit mask, never a completeness claim.
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t interrupt_wakeups;
    uint64_t package_idle_wakeups;
    uint64_t disk_read_bytes;
    uint64_t disk_write_bytes;
    uint64_t resident_bytes;
    uint64_t process_start_abstime; // Stable BSD start time in microseconds.
    char name[HG_PROCESS_NAME_LENGTH];
    char path[HG_PROCESS_PATH_LENGTH];
} HGProcessSample;

typedef struct {
    uint64_t user;
    uint64_t system;
    uint64_t idle;
    uint64_t nice;
} HGHostCPUTicks;

// Read-only task scheduling state used only after an explicit user action.
// `pti_maxpriority` changes when taskpolicy moves a task into Darwin
// background scheduling, while ordinary BSD priority often stays unchanged.
// Keep this separate from the periodic process sample so the resident monitor
// never pays for scheduler introspection on every refresh.
typedef struct {
    int32_t policy;
    int32_t priority;
    int32_t max_priority;
    uint32_t thread_count;
    uint32_t readable_threads;
    uint32_t background_threads;
} HGProcessScheduling;

typedef enum {
    HG_TEMP_UNAVAILABLE = 0,
    HG_TEMP_APPLE_SMC = 1,
    HG_TEMP_IOHID = 2,
} HGTemperatureBackend;

typedef struct {
    double cpu_celsius;
    uint32_t sensor_count;
    HGTemperatureBackend backend;
} HGTemperatureSample;

int32_t hg_collect_processes(HGProcessSample *samples, int32_t capacity);
int32_t hg_read_process(int32_t pid, HGProcessSample *sample);
int32_t hg_read_self_footprint(uint64_t *bytes);
int32_t hg_read_host_cpu_ticks(HGHostCPUTicks *ticks);
int32_t hg_read_load_average(double *one_minute);
int32_t hg_read_process_scheduling(int32_t pid, HGProcessScheduling *scheduling);
// Best-effort, read-only AppleSMC CPU sensor estimate. Apple Silicon uses the
// native `flt ` keys and Intel uses legacy `sp78` keys. Returns zero on
// unsupported hardware, access denial, private API changes, or invalid data.
int32_t hg_read_cpu_temperature(HGTemperatureSample *sample);

#endif
