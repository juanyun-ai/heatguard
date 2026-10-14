#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
# Match the release build's bounded concurrency while other work is running.
/usr/bin/swift build -j 2
"$project_dir/.build/debug/HeatGuard" --self-test
"$project_dir/.build/debug/HeatGuard" --integration-test

measurement_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/heatguard-measure-tests.XXXXXX")"
trap 'rm -f "$measurement_test_dir/MeasureIdleTests" "$measurement_test_dir/TemperatureKeyClassificationTests"; rmdir "$measurement_test_dir"' EXIT
xcrun --sdk macosx clang -O2 -std=c11 -Wall -Wextra -Wpedantic \
    "$project_dir/Tools/MeasureIdleTests.c" -o "$measurement_test_dir/MeasureIdleTests"
"$measurement_test_dir/MeasureIdleTests"
xcrun --sdk macosx clang -O2 -std=c11 -Wall -Wextra -Wpedantic \
    -I "$project_dir/Sources/HeatGuardNative/include" \
    "$project_dir/Tools/TemperatureKeyClassificationTests.c" \
    -framework CoreFoundation -framework IOKit \
    -o "$measurement_test_dir/TemperatureKeyClassificationTests"
"$measurement_test_dir/TemperatureKeyClassificationTests"
