#!/usr/bin/env python3
"""通过 GitHub Git Data API 推送本地变更，用于 git push over HTTPS 被网络阻断时的兜底。

只调用 `gh api` 完成 HTTP 请求，认证完全复用已登录的 gh CLI。
用法: python push-via-api.py <owner/repo> <base_ref> <head_ref> <commit_message_file>
"""
import base64
import json
import subprocess
import sys

REPO_DIR = r"C:/Users/Willie_Wang/WorkBuddy/2026-09-23-12-49-52/openwrt-r1c-gateway"


def gh(*args, stdin=None):
    cmd = ["gh", "api", *args]
    proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                          encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(
            f"gh api {' '.join(args)} 失败 (exit {proc.returncode})\n"
            f"stdout: {proc.stdout[:2000]}\nstderr: {proc.stderr[:2000]}\n"
            f"body: {(stdin or '')[:2000]}"
        )
    return proc.stdout


def git(*args):
    return subprocess.run(["git", "-C", REPO_DIR, *args], capture_output=True,
                          check=True).stdout


def main():
    repo, base_ref, head_ref, msgfile = sys.argv[1:5]

    with open(msgfile, encoding="utf-8") as fh:
        message = fh.read().strip()

    # 远程当前 tree
    remote = json.loads(gh(f"repos/{repo}/commits/{base_ref}"))
    parent_sha = remote["sha"]
    base_tree = remote["commit"]["tree"]["sha"]

    # 本地相对 base 变更的文件清单
    changed = git("diff", "--name-only", base_ref, head_ref).decode().split()
    changed = [c.strip() for c in changed if c.strip()]
    print(f"变更文件 {len(changed)} 个: {changed}")

    tree_entries = []
    for path in changed:
        # 用 git blob 内容，确保与仓库对象一致（含 LF 规范化后的形态）
        blob = git("rev-parse", f"{head_ref}:{path}").decode().strip()
        content = git("cat-file", "blob", blob)
        b64 = base64.b64encode(content).decode()
        payload = json.dumps({"content": b64, "encoding": "base64"})
        try:
            out = gh("-X", "POST", f"repos/{repo}/git/blobs", "--input", "-",
                     stdin=payload)
        except subprocess.CalledProcessError as exc:
            print(f"!! blob 创建失败 {path}: {exc.stderr}")
            raise
        blob_sha = json.loads(out)["sha"]
        tree_entries.append({"path": path, "mode": "100644", "type": "blob",
                             "sha": blob_sha})
        print(f"  blob {path} -> {blob_sha[:8]}")

    tree_payload = json.dumps({"base_tree": base_tree, "tree": tree_entries})
    tree_sha = json.loads(
        gh("-X", "POST", f"repos/{repo}/git/trees", "--input", "-", stdin=tree_payload)
    )["sha"]
    print(f"新 tree: {tree_sha}")

    commit_payload = json.dumps({"message": message, "tree": tree_sha,
                                 "parents": [parent_sha]})
    new_commit = json.loads(
        gh("-X", "POST", f"repos/{repo}/git/commits", "--input", "-", stdin=commit_payload)
    )["sha"]
    print(f"新 commit: {new_commit[:8]}")

    gh("-X", "PATCH", f"repos/{repo}/git/refs/heads/main",
       "-f", "sha=" + new_commit)
    print(f"✅ 已更新 refs/heads/main -> {new_commit[:8]}")
    print(f"   https://github.com/{repo}/commit/{new_commit}")


if __name__ == "__main__":
    main()
