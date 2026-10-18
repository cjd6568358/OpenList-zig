"""设备/打包机 root 账号口令的唯一来源（口令本身**不入库**）。

历史教训（2026-10-18）：口令曾硬编码在 20 多个脚本与文档里，随 git 历史
外泄到远端；清理时把历史重写了一遍。此后一律从这里取，别再写死。

取值顺序：
  1. 环境变量 ``OLZ_ROOT_PWD``
  2. ``~/.olz_root_pwd``（推荐；仓库外，最不容易误提交）
  3. ``tools/.root_pwd``（仓库内但已 gitignore）

用法（脚本在 tools/ 下直接运行，sys.path[0] 就是 tools/）::

    from creds import root_pwd
    PWD = root_pwd()
"""

from __future__ import annotations

import os
from pathlib import Path


def root_pwd() -> str:
    v = os.environ.get("OLZ_ROOT_PWD", "").strip()
    if v:
        return v
    for p in (Path.home() / ".olz_root_pwd", Path(__file__).with_name(".root_pwd")):
        try:
            if p.is_file():
                text = p.read_text(encoding="utf-8").strip()
                if text:
                    return text
        except OSError:
            pass
    raise RuntimeError(
        "未找到设备 root 口令：请设置环境变量 OLZ_ROOT_PWD，"
        "或写入 ~/.olz_root_pwd（内容为口令本身）"
    )
