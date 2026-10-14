#include "HeatGuardNative.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Optional Celsius provider derived from the read-only AppleSMC strategy in
// macmon v0.8.2. It is isolated from ProcessInfo.thermalState: any failure
// here must simply return unavailable and must never trigger an action.
//
// Apple Silicon exposes CPU sensors as native-endian `flt ` keys through the
// AppleSMCKeysEndpoint service. Older Intel Macs expose the legacy AppleSMC
// service and normally publish CPU sensors as signed fixed-point `sp78` keys
// (for example TC0P/TC0D). Both protocols use the same read-only selectors;
// keeping the format decoding here makes the Universal 2 binary honest on
// Intel instead of treating an x86_64 slice as temperature-capable merely
// because it compiles.

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} HGSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_limit;
    uint32_t gpu_limit;
    uint32_t memory_limit;
} HGSMCPowerLimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} HGSMCKeyInfo;

typedef struct {
    uint32_t key;
    HGSMCVersion version;
    HGSMCPowerLimit power_limit;
    HGSMCKeyInfo key_info;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} HGSMCKeyData;

enum {
    HG_SMC_SELECTOR = 2,
    HG_SMC_CMD_READ_BYTES = 5,
    HG_SMC_CMD_READ_INDEX = 8,
    HG_SMC_CMD_READ_KEY_INFO = 9,
    HG_SMC_TYPE_FLOAT = 0x666c7420,
    HG_SMC_TYPE_SP78 = 0x73703738,
    HG_SMC_MAX_CPU_KEYS = 256,
};

typedef enum {
    HG_SMC_FORMAT_FLOAT = 1,
    HG_SMC_FORMAT_SP78 = 2,
} HGSMCValueFormat;

typedef enum {
    HG_SMC_BACKEND_UNKNOWN = 0,
    HG_SMC_BACKEND_APPLE_SILICON = 1,
    HG_SMC_BACKEND_INTEL_LEGACY = 2,
} HGSMCBackend;

typedef struct {
    uint32_t key;
    HGSMCKeyInfo info;
    HGSMCValueFormat format;
} HGSMCCachedKey;

static pthread_mutex_t hg_smc_cache_lock = PTHREAD_MUTEX_INITIALIZER;
static HGSMCCachedKey hg_smc_cpu_keys[HG_SMC_MAX_CPU_KEYS];
static uint32_t hg_smc_cpu_key_count = 0;
static bool hg_smc_cache_ready = false;
static HGSMCBackend hg_smc_cache_backend = HG_SMC_BACKEND_UNKNOWN;

static bool hg_valid_temperature(double value) {
    return isfinite(value) && value > 0.0 && value <= 150.0;
}

static uint32_t hg_fourcc(const char text[4]);

static bool hg_cpu_smc_key(uint32_t key, HGSMCBackend backend) {
    const uint8_t first = (uint8_t)(key >> 24);
    const uint8_t second = (uint8_t)(key >> 16);
    const uint8_t third = (uint8_t)(key >> 8);
    const uint8_t fourth = (uint8_t)key;
    if (first != 'T') return false;

    // The SMC key namespace is private and model-dependent. This is an
    // execution-safety allowlist, not a general sensor browser: accepting an
    // unknown key can turn a board, charger, PCIe, GPU, or proximity reading
    // into evidence for terminating a user process. Unknown keys fail closed.
    if (backend == HG_SMC_BACKEND_APPLE_SILICON) {
        // Stable CPU-die aggregates used by Apple Silicon sensor maps.
        if (key == hg_fourcc("TCMz") || key == hg_fourcc("TCMb")
            || key == hg_fourcc("TCDX")) return true;

        // M-series CPU core/cluster/die keys use lowercase `p`/`e`. The
        // third byte is constrained to the CPU families seen in the
        // cross-model maps (M1-M4); this deliberately excludes keys such as
        // power-delivery `TPD*` and any future unclassified `Tp?*` family.
        const bool cpu_performance_family = second == 'p'
            && (third == '0' || third == '1' || third == '2'
                || third == '3' || third == 'x');
        const bool cpu_efficiency_family = second == 'e' && third == '0';
        return cpu_performance_family || cpu_efficiency_family;
    }

    if (backend == HG_SMC_BACKEND_INTEL_LEGACY) {
        // Legacy Intel CPU die/package/core keys. TC0P/TC0p (proximity),
        // TC0H (heatsink), TC0G/TC0J/TC0T (adjustment/trend), TCHP
        // (heatpipe), and TC* system/GPU keys are intentionally excluded.
        if (key == hg_fourcc("TCAD")) return true;
        if (second != 'C' || (third < '0' || third > '9')) return false;
        return fourth == 'D' || fourth == 'E' || fourth == 'F'
            || fourth == 'c' || fourth == 'C';
    }
    return false;
}

static kern_return_t hg_smc_call(
    io_connect_t connection,
    const HGSMCKeyData *input,
    HGSMCKeyData *output
) {
    size_t output_size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        HG_SMC_SELECTOR,
        input,
        sizeof(*input),
        output,
        &output_size
    );
    if (result != KERN_SUCCESS || output_size < sizeof(*output)) {
        return result == KERN_SUCCESS ? kIOReturnUnderrun : result;
    }
    return output->result == 0 ? KERN_SUCCESS : kIOReturnError;
}

static uint32_t hg_fourcc(const char text[4]) {
    return ((uint32_t)(uint8_t)text[0] << 24)
        | ((uint32_t)(uint8_t)text[1] << 16)
        | ((uint32_t)(uint8_t)text[2] << 8)
        | (uint32_t)(uint8_t)text[3];
}

static bool hg_smc_key_info(io_connect_t connection, uint32_t key, HGSMCKeyInfo *info) {
    HGSMCKeyData input = {0};
    HGSMCKeyData output = {0};
    input.key = key;
    input.data8 = HG_SMC_CMD_READ_KEY_INFO;
    if (hg_smc_call(connection, &input, &output) != KERN_SUCCESS) return false;
    *info = output.key_info;
    return true;
}

static bool hg_smc_read_data(
    io_connect_t connection,
    uint32_t key,
    const HGSMCKeyInfo *info,
    HGSMCKeyData *output
) {
    HGSMCKeyData input = {0};
    input.key = key;
    input.key_info = *info;
    input.data8 = HG_SMC_CMD_READ_BYTES;
    return hg_smc_call(connection, &input, output) == KERN_SUCCESS;
}

static io_connect_t hg_smc_open_named(const char *wanted_name) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (matching == NULL || IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    ) != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_connect_t connection = IO_OBJECT_NULL;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name = {0};
        if (IORegistryEntryGetName(service, name) == KERN_SUCCESS
            && strcmp(name, wanted_name) == 0
            && IOServiceOpen(service, mach_task_self(), 0, &connection) != KERN_SUCCESS) {
            connection = IO_OBJECT_NULL;
        }
        IOObjectRelease(service);
        if (connection != IO_OBJECT_NULL) break;
    }
    IOObjectRelease(iterator);
    return connection;
}

static io_connect_t hg_smc_open(HGSMCBackend *backend) {
    if (backend != NULL) *backend = HG_SMC_BACKEND_UNKNOWN;
    // Prefer the Apple Silicon endpoint. Some systems expose both service
    // names; opening the legacy service first can make a valid endpoint look
    // unavailable because its key table is different.
    io_connect_t connection = hg_smc_open_named("AppleSMCKeysEndpoint");
    if (connection != IO_OBJECT_NULL) {
        if (backend != NULL) *backend = HG_SMC_BACKEND_APPLE_SILICON;
        return connection;
    }
    connection = hg_smc_open_named("AppleSMC");
    if (connection != IO_OBJECT_NULL && backend != NULL) {
        *backend = HG_SMC_BACKEND_INTEL_LEGACY;
    }
    return connection;
}

static bool hg_smc_value_format(const HGSMCKeyInfo *info, HGSMCValueFormat *format) {
    if (info == NULL || format == NULL) return false;
    if (info->data_type == HG_SMC_TYPE_FLOAT && info->data_size == sizeof(float)) {
        *format = HG_SMC_FORMAT_FLOAT;
        return true;
    }
    // `sp78` is a signed 8.8 fixed-point Celsius value. The SMC reports two
    // bytes for this type; accepting only that width avoids interpreting an
    // unrelated integer key as a temperature.
    if (info->data_type == HG_SMC_TYPE_SP78 && info->data_size == 2) {
        *format = HG_SMC_FORMAT_SP78;
        return true;
    }
    return false;
}

static bool hg_smc_decode_temperature(const HGSMCCachedKey *cached,
                                       const HGSMCKeyData *value,
                                       double *temperature) {
    if (cached == NULL || value == NULL || temperature == NULL) return false;
    double decoded = 0.0;
    if (cached->format == HG_SMC_FORMAT_FLOAT) {
        float native_value = 0.0f;
        memcpy(&native_value, value->bytes, sizeof(native_value));
        decoded = native_value;
    } else if (cached->format == HG_SMC_FORMAT_SP78) {
        const int16_t raw = (int16_t)(((uint16_t)value->bytes[0] << 8)
                                      | (uint16_t)value->bytes[1]);
        decoded = (double)raw / 256.0;
    } else {
        return false;
    }
    if (!hg_valid_temperature(decoded)) return false;
    *temperature = decoded;
    return true;
}

static bool hg_read_smc(HGTemperatureSample *sample) {
    pthread_mutex_lock(&hg_smc_cache_lock);
    HGSMCBackend backend = HG_SMC_BACKEND_UNKNOWN;
    io_connect_t connection = hg_smc_open(&backend);
    if (connection == IO_OBJECT_NULL) {
        pthread_mutex_unlock(&hg_smc_cache_lock);
        return false;
    }

    // If the service/backend changes, never reuse a key table from the other
    // namespace. This is mostly defensive for tests, OS transitions, and
    // future machines that expose both services.
    if (hg_smc_cache_ready && hg_smc_cache_backend != backend) {
        hg_smc_cache_ready = false;
        hg_smc_cpu_key_count = 0;
        hg_smc_cache_backend = HG_SMC_BACKEND_UNKNOWN;
    }

    if (!hg_smc_cache_ready) {
        HGSMCKeyInfo count_info = {0};
        HGSMCKeyData count_data = {0};
        uint32_t count_key = hg_fourcc("#KEY");
        if (!hg_smc_key_info(connection, count_key, &count_info)
            || !hg_smc_read_data(connection, count_key, &count_info, &count_data)) {
            IOServiceClose(connection);
            pthread_mutex_unlock(&hg_smc_cache_lock);
            return false;
        }
        uint32_t key_count = ((uint32_t)count_data.bytes[0] << 24)
            | ((uint32_t)count_data.bytes[1] << 16)
            | ((uint32_t)count_data.bytes[2] << 8)
            | (uint32_t)count_data.bytes[3];
        if (key_count == 0 || key_count > 16384) {
            IOServiceClose(connection);
            pthread_mutex_unlock(&hg_smc_cache_lock);
            return false;
        }

        uint32_t cached_count = 0;
        for (uint32_t index = 0; index < key_count; index++) {
            HGSMCKeyData index_input = {0};
            HGSMCKeyData index_output = {0};
            index_input.data8 = HG_SMC_CMD_READ_INDEX;
            index_input.data32 = index;
            if (hg_smc_call(connection, &index_input, &index_output) != KERN_SUCCESS
                || !hg_cpu_smc_key(index_output.key, backend)) continue;
            HGSMCKeyInfo info = {0};
            HGSMCValueFormat format = 0;
            if (!hg_smc_key_info(connection, index_output.key, &info)
                || !hg_smc_value_format(&info, &format)) continue;
            if (cached_count == HG_SMC_MAX_CPU_KEYS) break;
            hg_smc_cpu_keys[cached_count++] = (HGSMCCachedKey) {
                .key = index_output.key,
                .info = info,
                .format = format,
            };
        }
        if (cached_count == 0) {
            IOServiceClose(connection);
            pthread_mutex_unlock(&hg_smc_cache_lock);
            return false;
        }
        hg_smc_cpu_key_count = cached_count;
        hg_smc_cache_backend = backend;
        hg_smc_cache_ready = true;
    }

    double hottest = 0.0;
    uint32_t valid_count = 0;
    for (uint32_t index = 0; index < hg_smc_cpu_key_count; index++) {
        HGSMCCachedKey cached = hg_smc_cpu_keys[index];
        HGSMCKeyData value = {0};
        if (!hg_smc_read_data(connection, cached.key, &cached.info, &value)) continue;
        double temperature = 0.0;
        if (hg_smc_decode_temperature(&cached, &value, &temperature)) {
            if (valid_count == 0 || temperature > hottest) hottest = temperature;
            valid_count++;
        }
    }
    IOServiceClose(connection);
    if (valid_count == 0) {
        hg_smc_cache_ready = false;
        hg_smc_cpu_key_count = 0;
        hg_smc_cache_backend = HG_SMC_BACKEND_UNKNOWN;
    }
    pthread_mutex_unlock(&hg_smc_cache_lock);
    if (valid_count == 0) return false;

    // Use the hottest valid CPU sensor rather than an average. A single hot
    // core/die must not be diluted by cooler efficiency cores or proximity
    // sensors when deciding whether to accumulate a long thermal incident.
    sample->cpu_celsius = hottest;
    sample->sensor_count = valid_count;
    sample->backend = HG_TEMP_APPLE_SMC;
    return true;
}

int32_t hg_read_cpu_temperature(HGTemperatureSample *sample) {
    if (sample == NULL) return 0;
    memset(sample, 0, sizeof(*sample));
#if !defined(__arm64__) && !defined(__x86_64__)
    return 0;
#else
    return hg_read_smc(sample) ? 1 : 0;
#endif
}
