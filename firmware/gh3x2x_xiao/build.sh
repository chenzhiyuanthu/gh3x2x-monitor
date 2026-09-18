#!/bin/bash
# Build (and optionally flash) the GH3x2x firmware for XIAO nRF52840 Sense.
#   firmware/gh3x2x_xiao/build.sh            build only
#   firmware/gh3x2x_xiao/build.sh flash      build + upload to /dev/cu.usbmodem2101 (or $PORT)
set -euo pipefail
cd "$(dirname "$0")"
FQBN=Seeeduino:mbed:xiaonRF52840Sense
PORT="${PORT:-/dev/cu.usbmodem2101}"
G=src/goodix
INC="-I$PWD/src -I$PWD/$G/demo_kernel_code/kernel -I$PWD/$G/demo_kernel_code/driver/inc \
 -I$PWD/$G/demo_kernel_code/module/gh_agc -I$PWD/$G/demo_kernel_code/module/gh_ecg -I$PWD/$G/demo_kernel_code/module/gh_other \
 -I$PWD/$G/demo_kernel_code/module/gh_protocol -I$PWD/$G/demo_kernel_code/module/gh_soft_adt -I$PWD/$G/demo_kernel_code/module/gh_common \
 -I$PWD/$G/demo_algo_code/goodix_algo_application/inc -I$PWD/$G/demo_algo_code/goodix_algo_call/inc \
 -I$PWD/$G/demo_algo_code/goodix_algo_call/inc/hr_exc -I$PWD/$G/demo_algo_code/goodix_algo_call/inc/spo2_pre_exc \
 -I$PWD/$G/algo_params"
LIBS="$PWD/lib/libgh3x2x_drv_cortexM4l_band_gcc_softfp_common.a \
 $PWD/lib/cortex-m4_arm-gcc-4.9.3_o2-softfp_hr.a $PWD/lib/cortex-m4_arm-gcc-4.9.3_o2-softfp_spo2.a \
 $PWD/lib/cortex-m4_arm-gcc-4.9.3_o2-softfp_hrv.a $PWD/lib/cortex-m4_arm-gcc-4.9.3_o2-softfp_nadt.a \
 $PWD/lib/cortex-m4_arm-gcc-4.9.3_o2-softfp_common_dl.a $PWD/lib/cortex-m4_arm-gcc-4.9.3_o2-softfp_common_dsp.a -lm"
arduino-cli compile --fqbn $FQBN \
  --build-property "compiler.c.extra_flags=$INC -Wno-unused-variable -Wno-unused-function" \
  --build-property "compiler.cpp.extra_flags=$INC" \
  --build-property "compiler.libraries.ldflags=$LIBS" \
  --build-path "$PWD/build" .
if [ "${1:-}" = "flash" ]; then
  arduino-cli upload --fqbn $FQBN -p "$PORT" --input-dir "$PWD/build" .
fi
