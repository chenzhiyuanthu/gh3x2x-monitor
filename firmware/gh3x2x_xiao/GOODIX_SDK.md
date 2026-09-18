# 重建 `src/goodix/` 和 `lib/`（公开仓库不含汇顶 SDK）

汇顶的驱动/算法 SDK 是客户资料包里的保密内容（闭源 `.a`、算法网络参数、demo 源码），**不放进公开仓库**。
拿到 `GH3x2x/3. 软件设计/GH3X2X_V41xx版本算法驱动以及移植文档/V4300版本驱动库以及移植指南/` 这个目录后，按下面几步即可还原出可编译的工程：

```bash
cd firmware/gh3x2x_xiao
V="…/V4300版本驱动库以及移植指南"          # 资料包里的目录

# 1. demo 源码（已含 patch1~3）→ src/goodix/
mkdir -p src/goodix lib
7zz x "$V/3-demo_code-4300_patch1-3.7z" -osrc/goodix        # 得到 demo_kernel_code/ demo_algo_code/

# 2. 套上本仓库的改动（只动 gh_demo_config.h / gh_demo_inner.h / gh_demo_reg_array.c /
#    gh3x2x_demo_algo_config.h / gh3x2x_demo_algo_reg_array.c 这 5 个允许改的文件）
(cd src/goodix && patch -p1 < ../../goodix_sdk.patch)

# 3. 算法网络参数 → src/goodix/algo_params/（HR 用 04_EXCLUSIVE，SpO2 用 02_PREMIUM_EXCLUSIVE）
T=$(mktemp -d); 7zz x "$V/2-algo_lib-4300.7z" -o"$T" >/dev/null
mkdir -p src/goodix/algo_params
cp "$T"/algo-lib/algo_params/HR/04_EXCLUSIVE/*                                   src/goodix/algo_params/
cp "$T"/algo-lib/algo_params/SPO2/02_PREMIUM_EXCLUSIVE/goodix_spo2_*_7ecd2a.c    src/goodix/algo_params/
cp "$T"/algo-lib/algo_params/goodix_hrv_config.c "$T"/algo-lib/algo_params/goodix_nadt_config.c src/goodix/algo_params/

# 4. 静态库（Cortex-M4 / arm-gcc / softfp）→ lib/
cp "$T"/algo-lib/HR/04_EXCLUSIVE/GH_HR_exc_pv_v2.0.3.0/cortex-m4_arm-gcc-4.9.3_o2-softfp_hr.a        lib/
cp "$T"/algo-lib/SPO2/02_PREMIUM_EXCLUSIVE/GH_SPO2_pre_pv_v2.1.10.0/cortex-m4_arm-gcc-4.9.3_o2-softfp_spo2.a lib/
cp "$T"/algo-lib/HRV/GH_HRV_pre_pv_v1.0.1.0/cortex-m4_arm-gcc-4.9.3_o2-softfp_hrv.a                  lib/
cp "$T"/algo-lib/NADT/GH_NADT_pre_pv_v1.0.2.0/cortex-m4_arm-gcc-4.9.3_o2-softfp_nadt.a               lib/
cp "$T"/algo-lib/COMMON_DL/01_premium_and_exclusive/dlCom_pre2exc_pv_v1.3.0/cortex-m4_arm-gcc-4.9.3_o2-softfp_common_dl.a lib/
cp "$T"/algo-lib/COMMON_DSP/dsp_pv_v1.3.0/cortex-m4_arm-gcc-4.9.3_o2-softfp_common_dsp.a           lib/
7zz e "$V/1-drv_lib-4300.7z" -olib "1-drv_lib/M4_gcc_soft/_build/M4_gcc_soft/libgh3x2x_drv_cortexM4l_band_gcc_softfp_common.a"

./build.sh            # 或 ./build.sh flash
```

`goodix_sdk.patch` 是用 `diff -ruN` 从原始 demo 生成的，已验证"原始 demo + patch == 本工程的 src/goodix"。
