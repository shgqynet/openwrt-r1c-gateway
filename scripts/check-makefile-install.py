#!/usr/bin/env python3
"""校验 OpenWrt 包 Makefile 的 install 段：目标目录必须先 INSTALL_DIR。

【为什么需要】2026-10-17 在 package/r1c-gateway/Makefile 里新增
    $(INSTALL_BIN) ./files/etc/r1c/lan-guard.sh $(1)/etc/r1c/lan-guard.sh
却把它写在了 $(INSTALL_DIR) $(1)/etc/r1c **之前** —— install 不会自动建目录，
于是构建在跑了 1 小时 12 分之后才报
    install: cannot create regular file '.../etc/r1c/lan-guard.sh': No such file or directory
一小时白跑。这个错误在敲完 Makefile 的那一刻就能查出来，不必等编译。

用法：python3 scripts/check-makefile-install.py package/r1c-gateway/Makefile
"""
import re
import sys

TARGET = re.compile(r"\$\(INSTALL_(?:BIN|CONF|DATA)\)\s+\S+\s+\$\(1\)(\S+)")
MKDIR = re.compile(r"\$\(INSTALL_DIR\)\s+\$\(1\)(\S+)")


def check(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        print(f"::error::无法读取 {path}: {e}")
        return 1

    in_install = False
    made = set()          # 已 INSTALL_DIR 过的目录（含逐层父目录）
    errors = []

    def add_dir(d):
        d = d.rstrip("/")
        parts = d.split("/")
        for i in range(1, len(parts) + 1):
            made.add("/".join(parts[:i]))

    for i, line in enumerate(lines, 1):
        s = line.strip()
        if re.match(r"define\s+Package/\S+/install\b", s):
            in_install = True
            made = set()
            continue
        if s == "endef":
            in_install = False
            continue
        if not in_install:
            continue

        m = MKDIR.search(s)
        if m:
            add_dir(m.group(1))
            continue

        m = TARGET.search(s)
        if m:
            tgt = m.group(1)
            parent = tgt.rsplit("/", 1)[0] if "/" in tgt else ""
            if parent and parent not in made:
                errors.append((i, tgt, parent))

    if errors:
        for i, tgt, parent in errors:
            print(f"::error::{path}:{i}: 安装 {tgt} 时目录 {parent} 尚未创建"
                  f"（请把对应的 $(INSTALL_DIR) $(1){parent} 移到它之前）")
        print(f"共 {len(errors)} 处顺序错误 —— 不修的话构建会在一小时后失败")
        return 1

    print(f"✅ {path}: install 段顺序正确")
    return 0


if __name__ == "__main__":
    rc = 0
    for p in sys.argv[1:] or ["package/r1c-gateway/Makefile"]:
        rc |= check(p)
    sys.exit(rc)
