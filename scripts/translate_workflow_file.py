#!/usr/bin/env python3
"""Apply reviewed English translations to one kernel workflow at a time."""
import pathlib
import re
import sys

PATH = pathlib.Path(sys.argv[1])
REPLACEMENTS = {
    "name: 内核构建 - ": "name: Kernel Build - ",
    "KernelSU 变体": "KernelSU variant",
    "构建通道（正式=官方 Release 发行版，最新=上游最新提交）": "Build channel (Stable = official Release; Latest = upstream HEAD)",
    "正式 (Release)": "Stable (Release)",
    "最新 (HEAD)": "Latest (HEAD)",
    "自定义版本名 (可选)": "Custom version name (optional)",
    "自定义构建时间 (留空=自动获取当前北京时间) (示例 Tue Dec  1 08:10:00 UTC 2026)": "Custom build time (leave blank to use the current Beijing time; example: Tue Dec  1 08:10:00 UTC 2026)",
    "KPM 功能（仅SukiSU支持，开启未修补）": "KPM feature (SukiSU only; enabling it leaves it unpatched)",
    "Droidspaces 容器支持": "Droidspaces container support",
    "构建产物上传模式": "Build artifact upload mode",
    "仅上传 AnyKernel3.zip": "AnyKernel3.zip only",
    "上传全部": "Upload all",
    "KernelSU / SUSFS 模式": "KernelSU / SUSFS mode",
    "关闭": "Disabled",
    "禁用SUSFS": "Disable SUSFS",
    "禁用KSU": "Disable KernelSU",
    "启用 Droidspaces 容器 NTSync 支持（需启用 Droidspaces）": "Enable NTSync support for Droidspaces containers (Droidspaces must also be enabled)",
    "启用 ZRAM 压缩算法": "Enable the ZRAM compression algorithm",
    "启用 BBG 基带保护": "Enable BBG baseband protection",
    "启用 网络增强 (BBRv3 + IPSet + Qdisc + CIFS)": "Enable network enhancements (BBRv3 + IPSet + Qdisc + CIFS)",
    "启用 Re-Kernel 驱动": "Enable the Re-Kernel driver",
    "启用 NoMount 挂载元模块（需自行刷入配套模块）": "Enable the NoMount mount metamodule (the matching module must be flashed separately)",
    "应用 CVE-2026-43499 rtmutex 修复链": "Apply the CVE-2026-43499 rtmutex fix chain",
    "启用 一加 骁龙8 Elite/Gen5 支持": "Enable OnePlus Snapdragon 8 Elite / Gen 5 support",
    "功能不兼容或无法使用时自动跳过该功能（不中断构建）": "Automatically skip incompatible or unavailable features without stopping the build",
    "构建通道（从 main.yml 传入；直接触发时取本工作流拉取的管理器来源）": "Build channel (passed from main.yml; when triggered directly, uses the manager source selected by this workflow)",
    "是否从 main.yml 调用（内部使用）": "Whether this was called from main.yml (internal use)",
    "官方最新上传构建的 KernelSU 提交（从 main.yml 传入；直接触发时自动取本工作流拉取的管理器构建）": "KernelSU commit for the latest official uploaded build (passed from main.yml; when triggered directly, uses the manager build selected by this workflow)",
    "FinaSU 管理器签名证书 DER 尺寸（从 main.yml 传入；直接触发时自动取本工作流拉取的管理器证书）": "FinaSU manager signing certificate DER size (passed from main.yml; when triggered directly, uses the certificate fetched by this workflow)",
    "FinaSU 管理器签名证书 SHA256（从 main.yml 传入；直接触发时自动取本工作流拉取的管理器证书）": "FinaSU manager signing certificate SHA256 (passed from main.yml; when triggered directly, uses the certificate fetched by this workflow)",
    "管理器 versionCode（从 main.yml 传入；直接触发时自动取本工作流拉取的管理器版本）": "Manager versionCode (passed from main.yml; when triggered directly, uses the manager version fetched by this workflow)",
    "管理器作业被跳过（called_from_main）或失败时不阻塞构建；ksuCommit 为空时回退传入值或 main HEAD": "The build can proceed if the manager job is skipped (called_from_main) or fails; when ksuCommit is empty, it falls back to the supplied value or main HEAD",
    "仅在直接触发时运行，从 main.yml 调用时跳过": "Run only when triggered directly; skip when called from main.yml",
}
text = PATH.read_text()
for source, target in REPLACEMENTS.items():
    text = text.replace(source, target)
PATH.write_text(text)
remaining = [(i, line) for i, line in enumerate(text.splitlines(), 1) if re.search(r"[\u3400-\u9fff]", line)]
if remaining:
    print("Untranslated lines:")
    for number, line in remaining:
        print(f"{number}: {line}")
    raise SystemExit(1)
print(f"Translated {PATH}")
