#include "../Sources/HeatGuardNative/Temperature.c"
#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    const char *key;
    HGSMCBackend backend;
    bool expected;
} HGKeyCase;

static unsigned test_count = 0;
static unsigned failures = 0;

static void check_bool(const char *name, bool actual, bool expected) {
    test_count++;
    if (actual != expected) {
        fprintf(stderr, "FAIL %s expected=%d actual=%d\n", name, expected, actual);
        failures++;
    }
}

static void check_temperature(const char *name, HGSMCCachedKey cached,
                              HGSMCKeyData value, bool expected_valid,
                              double expected_celsius) {
    double actual_celsius = -1.0;
    const bool actual_valid = hg_smc_decode_temperature(&cached, &value, &actual_celsius);
    check_bool(name, actual_valid, expected_valid);
    if (expected_valid) {
        test_count++;
        if (!actual_valid || fabs(actual_celsius - expected_celsius) > 0.01) {
            fprintf(stderr, "FAIL %s expected_celsius=%.3f actual_celsius=%.3f\n",
                    name, expected_celsius, actual_celsius);
            failures++;
        }
    }
}

int main(void) {
    const HGKeyCase cases[] = {
        {"TCMz", HG_SMC_BACKEND_APPLE_SILICON, true},  // CPU-die maximum aggregate
        {"TCMb", HG_SMC_BACKEND_APPLE_SILICON, true},  // CPU-die average aggregate
        {"TCDX", HG_SMC_BACKEND_APPLE_SILICON, true},  // CPU-die aggregate
        {"Tp3X", HG_SMC_BACKEND_APPLE_SILICON, true},  // M3/M4 performance cluster
        {"Te06", HG_SMC_BACKEND_APPLE_SILICON, true},  // M2-M4 efficiency core/cluster
        {"TpD%", HG_SMC_BACKEND_APPLE_SILICON, false}, // Apple power-delivery IC
        {"Tp4X", HG_SMC_BACKEND_APPLE_SILICON, false}, // unrecognised CPU family
        {"Te1X", HG_SMC_BACKEND_APPLE_SILICON, false}, // unrecognised CPU family
        {"TC0D", HG_SMC_BACKEND_APPLE_SILICON, false}, // Intel-only spelling
        {"TCHP", HG_SMC_BACKEND_APPLE_SILICON, false}, // CPU heatpipe, not die/core
        {"Ts00", HG_SMC_BACKEND_APPLE_SILICON, false}, // SSD/SoC/enclosure family
        {"Tg0K", HG_SMC_BACKEND_APPLE_SILICON, false}, // GPU sensor

        {"TC0D", HG_SMC_BACKEND_INTEL_LEGACY, true},  // Intel CPU die
        {"TC1E", HG_SMC_BACKEND_INTEL_LEGACY, true},  // filtered CPU die
        {"TC9c", HG_SMC_BACKEND_INTEL_LEGACY, true},  // Intel CPU core
        {"TCAD", HG_SMC_BACKEND_INTEL_LEGACY, true},  // CPU package aggregate
        {"Te0F", HG_SMC_BACKEND_INTEL_LEGACY, false}, // PCIe slot sensor
        {"Tp0C", HG_SMC_BACKEND_INTEL_LEGACY, false}, // power supply sensor
        {"TC0P", HG_SMC_BACKEND_INTEL_LEGACY, false}, // CPU proximity
        {"TC0H", HG_SMC_BACKEND_INTEL_LEGACY, false}, // CPU heatsink
        {"TCSA", HG_SMC_BACKEND_INTEL_LEGACY, false}, // system agent
        {"TCGC", HG_SMC_BACKEND_INTEL_LEGACY, false}, // Intel GPU
        {"TCHP", HG_SMC_BACKEND_INTEL_LEGACY, false}, // CPU heatpipe
        {"TC0D", HG_SMC_BACKEND_UNKNOWN, false}, // backend is required
    };
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        const bool actual = hg_cpu_smc_key(hg_fourcc(cases[index].key), cases[index].backend);
        char description[64];
        (void)snprintf(description, sizeof(description), "CPU key classification: %s/%d",
                       cases[index].key, cases[index].backend);
        check_bool(description, actual, cases[index].expected);
    }

    HGSMCValueFormat format = 0;
    HGSMCKeyInfo info = {.data_type = HG_SMC_TYPE_FLOAT, .data_size = sizeof(float)};
    check_bool("SMC float format accepted", hg_smc_value_format(&info, &format)
               && format == HG_SMC_FORMAT_FLOAT, true);
    info = (HGSMCKeyInfo){.data_type = HG_SMC_TYPE_SP78, .data_size = 2};
    check_bool("SMC sp78 format accepted", hg_smc_value_format(&info, &format)
               && format == HG_SMC_FORMAT_SP78, true);
    info.data_size = 1;
    check_bool("SMC sp78 wrong width rejected", hg_smc_value_format(&info, &format), false);
    info = (HGSMCKeyInfo){.data_type = HG_SMC_TYPE_FLOAT, .data_size = 2};
    check_bool("SMC float wrong width rejected", hg_smc_value_format(&info, &format), false);
    info = (HGSMCKeyInfo){.data_type = hg_fourcc("ui16"), .data_size = 2};
    check_bool("SMC unrelated type rejected", hg_smc_value_format(&info, &format), false);

    HGSMCCachedKey cached = {.format = HG_SMC_FORMAT_FLOAT};
    HGSMCKeyData value = {0};
    const float float_temperature = 76.5f;
    memcpy(value.bytes, &float_temperature, sizeof(float_temperature));
    check_temperature("Apple Silicon float Celsius decode", cached, value, true, 76.5);
    const float nan_temperature = NAN;
    memcpy(value.bytes, &nan_temperature, sizeof(nan_temperature));
    check_temperature("NaN temperature rejected", cached, value, false, 0);
    const float infinite_temperature = INFINITY;
    memcpy(value.bytes, &infinite_temperature, sizeof(infinite_temperature));
    check_temperature("Infinite temperature rejected", cached, value, false, 0);
    const float zero_temperature = 0.0f;
    memcpy(value.bytes, &zero_temperature, sizeof(zero_temperature));
    check_temperature("Zero temperature rejected", cached, value, false, 0);
    const float out_of_range_temperature = 150.5f;
    memcpy(value.bytes, &out_of_range_temperature, sizeof(out_of_range_temperature));
    check_temperature("Out-of-range temperature rejected", cached, value, false, 0);

    cached.format = HG_SMC_FORMAT_SP78;
    value = (HGSMCKeyData){0};
    value.bytes[0] = 0x4c;
    value.bytes[1] = 0x80;
    check_temperature("Intel sp78 big-endian Celsius decode", cached, value, true, 76.5);
    value.bytes[0] = 0xff;
    value.bytes[1] = 0x80;
    check_temperature("Negative sp78 temperature rejected", cached, value, false, 0);
    value.bytes[0] = 0x00;
    value.bytes[1] = 0x00;
    check_temperature("Zero sp78 temperature rejected", cached, value, false, 0);
    value.bytes[0] = 0x96;
    value.bytes[1] = 0x80;
    check_temperature("Out-of-range sp78 temperature rejected", cached, value, false, 0);
    cached.format = 0;
    check_temperature("Unknown cached format rejected", cached, value, false, 0);

    if (failures != 0) return 1;
    printf("Temperature backend safety tests: %u/%u passed\n", test_count, test_count);
    return 0;
}
