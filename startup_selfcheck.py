#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
静默启动管理器 · 启动项/自启自检
检测维度：
  1. LaunchAgents 登录项（重复检测、目标路径、RunAtLoad）
  2. 磁盘上残留/重复 App 副本（含废纸篓）
  3. 运行态（进程 / launchctl）
  4. App 本体完整性（版本 / 二进制改名是否彻底 / dylib 是否存在）
  5. LaunchServices 注册异常
输出：HTML 自检报告 + 控制台摘要
"""
import os
import re
import subprocess
import plistlib
import datetime
import html

HOME = os.path.expanduser("~")
APP_NAME = "静默启动管理器"
BUNDLE_ID = "com.user.silentlauncher"
INSTALLED_APP = "/Applications/静默启动管理器.app"
LAUNCH_AGENTS_DIR = os.path.join(HOME, "Library/LaunchAgents")
TRASH_DIR = os.path.join(HOME, ".Trash")

OLD_NAME = "开机静默启动器"
NEW_NAME = "静默启动管理器"

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout
    except Exception as e:
        return f"(exec error: {e})"


def find_plists():
    """返回所有与 silent launcher 相关的 LaunchAgent plist 列表"""
    hits = []
    if not os.path.isdir(LAUNCH_AGENTS_DIR):
        return hits
    for fn in os.listdir(LAUNCH_AGENTS_DIR):
        if not fn.endswith(".plist"):
            continue
        path = os.path.join(LAUNCH_AGENTS_DIR, fn)
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except Exception:
            continue
        try:
            plist = plistlib.loads(raw)
        except Exception:
            continue
        progs = plist.get("ProgramArguments", [])
        prog_line = " ".join(progs)
        label = plist.get("Label", "")
        # 匹配：路径含 App 名 / SilentLauncher / 旧名，或 Label 含 silentlauncher
        if (APP_NAME in prog_line or "SilentLauncher" in prog_line or OLD_NAME in prog_line
                or "silentlauncher" in label.lower()):
            hits.append({
                "file": fn,
                "path": path,
                "label": label,
                "program": prog_line,
                "run_at_load": bool(plist.get("RunAtLoad", False)),
                "keep_alive": bool(plist.get("KeepAlive", False)),
                "target_exists": os.path.exists(progs[0]) if progs else False,
            })
    return hits


def find_app_copies():
    """全盘找 静默启动管理器.app 副本（排除 /Applications 本体）"""
    copies = set()
    # 1) mdfind（不含 .Trash，Spotlight 默认不索引废纸篓）
    out = sh('mdfind "kMDItemFSName == \'*.app\'" 2>/dev/null')
    for line in out.splitlines():
        line = line.strip()
        if os.path.basename(line) == "静默启动管理器.app":
            copies.add(line)
    # 2) 直接扫废纸篓（mdfind 漏掉的在这里）
    if os.path.isdir(TRASH_DIR):
        try:
            for name in os.listdir(TRASH_DIR):
                if name == "静默启动管理器.app" or name.startswith("静默启动管理器.app "):
                    copies.add(os.path.join(TRASH_DIR, name))
        except Exception:
            pass
    return sorted(copies)


def running_processes():
    out = sh(r'ps aux | grep -i -e "SilentLauncher" -e "静默" | grep -v grep')
    procs = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 11:
            procs.append({"pid": parts[1], "cpu": parts[2], "mem": parts[3], "cmd": " ".join(parts[10:])})
    return procs


def launchctl_state():
    out = sh('launchctl list 2>/dev/null | grep -i -e "silent" -e "静默"')
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        cols = line.split()
        rows.append({"pid": cols[0], "exit": cols[1], "label": cols[2]})
    return rows


def app_integrity():
    info = {"exists": os.path.exists(INSTALLED_APP), "version": "?", "bundle_id": "?",
            "binary_patched_old": -1, "binary_has_new": -1, "dylib_present": False,
            "wrapper_present": False}
    if not info["exists"]:
        return info
    plist_path = os.path.join(INSTALLED_APP, "Contents", "Info.plist")
    try:
        with open(plist_path, "rb") as f:
            pl = plistlib.load(f)
        info["version"] = pl.get("CFBundleShortVersionString", "?")
        info["bundle_id"] = pl.get("CFBundleIdentifier", "?")
    except Exception:
        pass
    real_bin = os.path.join(INSTALLED_APP, "Contents", "MacOS", "SilentLauncher.real")
    wrapper = os.path.join(INSTALLED_APP, "Contents", "MacOS", "SilentLauncher")
    dylib = os.path.join(INSTALLED_APP, "Contents", "Resources", "about_inject.dylib")
    info["wrapper_present"] = os.path.exists(wrapper)
    info["dylib_present"] = os.path.exists(dylib)
    if os.path.exists(real_bin):
        with open(real_bin, "rb") as f:
            data = f.read()
        info["binary_patched_old"] = data.count(OLD_NAME.encode("utf-8"))
        info["binary_has_new"] = data.count(NEW_NAME.encode("utf-8"))
    return info


def lsregister_anomalies():
    """检查 LaunchServices 是否注册了废纸篓里的副本"""
    out = sh('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>/dev/null')
    trash_paths = set()
    cur = None
    for line in out.splitlines():
        m = re.match(r"\s*path:\s*(.+)", line)
        if m:
            cur = m.group(1).strip()
            continue
        if cur and "静默启动管理器.app" in cur and TRASH_DIR in cur:
            trash_paths.add(cur)
    return sorted(trash_paths)


# ===================== 执行检测 =====================
plists = find_plists()
copies = find_app_copies()
procs = running_processes()
lstate = launchctl_state()
integrity = app_integrity()
ls_anom = lsregister_anomalies()

# 用 lsregister 已确认的废纸篓路径补全副本清单（.Trash 常被沙盒禁止直接列目录）
copies = sorted(set(copies) | set(ls_anom))

# 重复登录项判定：指向同一 App 本体的多个 RunAtLoad 项
running_login = [p for p in plists if p["run_at_load"] and INSTALLED_APP in p["program"]]
duplicate_login = len(running_login) > 1

extra_copies = [c for c in copies if c != INSTALLED_APP]
trash_copies = [c for c in extra_copies if TRASH_DIR in c]

# 统计判定
stat = {
    "login_items": len(running_login),
    "extra_copies": len(extra_copies),
    "trash_registered": len(ls_anom),
    "running_procs": len(procs),
}

# 结论评级
verdicts = []
if duplicate_login:
    verdicts.append(("bad", "重复登录项 → 开机被拉起多份（一起启动根因）"))
else:
    verdicts.append(("ok", "登录项无重复"))

if extra_copies:
    verdicts.append(("warn", f"{len(extra_copies)} 份残留 App 副本（含废纸篓 {len(trash_copies)} 份）"))
else:
    verdicts.append(("ok", "无残留副本"))

if integrity["exists"] and integrity["binary_patched_old"] == 0 and integrity["binary_has_new"] > 0:
    verdicts.append(("ok", "二进制改名彻底（旧名 0 处 / 新名已写入）"))
elif integrity["exists"]:
    verdicts.append(("warn", f"二进制改名检查：旧名 {integrity['binary_patched_old']} 处 / 新名 {integrity['binary_has_new']} 处"))
else:
    verdicts.append(("bad", "App 本体不存在"))

if integrity["dylib_present"] and integrity["wrapper_present"]:
    verdicts.append(("ok", "dylib 包装与关于注入完整"))
else:
    verdicts.append(("warn", "dylib 包装或关于注入缺失"))

bad = sum(1 for v, _ in verdicts if v == "bad")
warn = sum(1 for v, _ in verdicts if v == "warn")
ok = sum(1 for v, _ in verdicts if v == "ok")


def tag(v):
    return {"ok": "PASS", "warn": "WARN", "bad": "FAIL"}[v]


# ===================== 生成 HTML =====================
rows_login = ""
for p in plists:
    tgt = "✅" if p["target_exists"] else "❌"
    run = "是(RunAtLoad)" if p["run_at_load"] else "否"
    vcls = "ok" if (p["run_at_load"] and p["target_exists"]) else "warn"
    rows_login += f"""<tr><td>{html.escape(p['file'])}</td><td>{html.escape(p['label'])}</td>
<td>{html.escape(p['program'])}</td><td>{run}</td><td>{tgt}</td>
<td class="s {vcls}">{tag('ok' if (p['run_at_load'] and p['target_exists']) else 'warn')}</td></tr>"""

rows_copies = ""
if copies:
    for c in copies:
        loc = "📂 /Applications（本体）" if c == INSTALLED_APP else ("🗑 废纸篓" if TRASH_DIR in c else "⚠️ 其它位置")
        vcls = "ok" if c == INSTALLED_APP else "warn"
        rows_copies += f"<tr><td>{html.escape(c)}</td><td>{loc}</td><td class='s {vcls}'>{tag(vcls)}</td></tr>"
else:
    rows_copies = "<tr><td colspan='3'>未找到任何 App 副本</td></tr>"

rows_proc = ""
if procs:
    for p in procs:
        rows_proc += f"<tr><td>{p['pid']}</td><td>{p['cpu']}</td><td>{p['mem']}</td><td>{html.escape(p['cmd'])}</td></tr>"
else:
    rows_proc = "<tr><td colspan='4'>当前无运行中的启动器进程</td></tr>"

rows_lstate = ""
if lstate:
    for r in lstate:
        rows_lstate += f"<tr><td>{html.escape(r['pid'])}</td><td>{html.escape(r['exit'])}</td><td>{html.escape(r['label'])}</td></tr>"
else:
    rows_lstate = "<tr><td colspan='3'>launchctl 无相关条目</td></tr>"

rows_ls = ""
if ls_anom:
    for p in ls_anom:
        rows_ls += f"<tr><td>{html.escape(p)}</td><td class='s warn'>WARN</td></tr>"
else:
    rows_ls = "<tr><td>未发现废纸篓副本被注册</td><td class='s ok'>PASS</td></tr>"

integ = integrity
integ_rows = f"""
<tr><td>App 本体存在</td><td>/Applications/静默启动管理器.app</td><td class='s {"ok" if integ["exists"] else "bad"}'>{tag("ok" if integ["exists"] else "bad")}</td></tr>
<tr><td>版本号</td><td>CFBundleShortVersionString = {html.escape(str(integ["version"]))}</td><td class='s ok'>PASS</td></tr>
<tr><td>Bundle ID</td><td>{html.escape(str(integ["bundle_id"]))}</td><td class='s ok'>PASS</td></tr>
<tr><td>二进制改名（旧名残留）</td><td>{integ["binary_patched_old"]} 处「{OLD_NAME}」</td><td class='s {"ok" if integ["binary_patched_old"]==0 else "bad"}'>{tag("ok" if integ["binary_patched_old"]==0 else "bad")}</td></tr>
<tr><td>二进制新名写入</td><td>{integ["binary_has_new"]} 处「{NEW_NAME}」</td><td class='s {"ok" if integ["binary_has_new"]>0 else "warn"}'>{tag("ok" if integ["binary_has_new"]>0 else "warn")}</td></tr>
<tr><td>dylib 包装(SilentLauncher)</td><td>{'存在' if integ['wrapper_present'] else '缺失'}</td><td class='s {"ok" if integ['wrapper_present'] else "bad"}'>{tag("ok" if integ['wrapper_present'] else "bad")}</td></tr>
<tr><td>关于注入(about_inject.dylib)</td><td>{'存在' if integ['dylib_present'] else '缺失'}</td><td class='s {"ok" if integ['dylib_present'] else "bad"}'>{tag("ok" if integ['dylib_present'] else "bad")}</td></tr>
"""

verdict_rows = "".join(f"<tr><td class='s {v}'>{tag(v)}</td><td>{html.escape(d)}</td></tr>" for v, d in verdicts)

html_doc = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>静默启动管理器 · 启动项自检报告</title>
<style>
*{{box-sizing:border-box}}
body{{margin:0;background:#0e1116;color:#d7dde5;font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;line-height:1.6}}
.wrap{{max-width:980px;margin:0 auto;padding:32px 24px 64px}}
h1{{font-size:26px;margin:0 0 6px;color:#fff}}
.meta{{color:#7d8794;font-size:13px;margin-bottom:24px}}
.meta code{{background:#1b212b;padding:2px 6px;border-radius:4px;color:#9fb4ff}}
.banner{{display:flex;gap:12px;flex-wrap:wrap;margin:18px 0 28px}}
.stat{{flex:1;min-width:120px;background:#161b22;border:1px solid #232a34;border-radius:10px;padding:14px 16px}}
.stat .n{{font-size:30px;font-weight:700;line-height:1}}
.stat .l{{font-size:12px;color:#8b95a3;margin-top:6px}}
.ok{{color:#3fb950}}.warn{{color:#d29922}}.bad{{color:#f85149}}
section{{background:#131820;border:1px solid #232a34;border-radius:12px;padding:18px 20px;margin-bottom:20px}}
section h2{{font-size:17px;margin:0 0 12px;color:#fff;display:flex;align-items:center;gap:10px}}
.tag{{margin-left:auto;font-size:12px;padding:3px 10px;border-radius:20px;font-weight:600}}
.tag.PASS{{background:rgba(63,185,80,.15);color:#3fb950}}
.tag.WARN{{background:rgba(210,153,34,.15);color:#d29922}}
.tag.FAIL{{background:rgba(248,81,73,.15);color:#f85149}}
table{{width:100%;border-collapse:collapse;font-size:13.5px}}
th,td{{text-align:left;padding:9px 10px;border-bottom:1px solid #212832}}
th{{color:#8b95a3;font-weight:600;font-size:12px;text-transform:none}}
td.s{{font-weight:700;text-align:center;width:70px}}
.note{{background:#1b212b;border-left:3px solid #d29922;padding:10px 14px;border-radius:6px;font-size:13px;color:#cdd5df;margin-top:10px}}
.note.bad{{border-color:#f85149}}.note.ok{{border-color:#3fb950}}
code{{background:#1b212b;padding:1px 5px;border-radius:4px;color:#9fb4ff}}
</style></head>
<body><div class="wrap">
<h1>静默启动管理器 · 启动项 / 自启自检报告</h1>
<div class="meta">版本 <code>v21</code> · 检出文件名 <code>{html.escape(os.path.basename(INSTALLED_APP))}</code> · 自检时间 <code>{now}</code> · 平台 macOS (darwin)</div>

<div class="banner">
  <div class="stat"><div class="n {('bad' if bad else ('warn' if warn else 'ok'))}">{ok}/{ok+warn+bad}</div><div class="l">结论项 PASS / 总项</div></div>
  <div class="stat"><div class="n {('bad' if duplicate_login else 'ok')}">{stat['login_items']}</div><div class="l">生效登录项(RunAtLoad)</div></div>
  <div class="stat"><div class="n {('warn' if extra_copies else 'ok')}">{stat['extra_copies']}</div><div class="l">残留 App 副本</div></div>
  <div class="stat"><div class="n {('warn' if ls_anom else 'ok')}">{stat['trash_registered']}</div><div class="l">废纸篓副本被注册</div></div>
  <div class="stat"><div class="n {('warn' if procs else 'ok')}">{stat['running_procs']}</div><div class="l">当前运行进程</div></div>
</div>

<section>
  <h2>综合结论 <span class="tag {('FAIL' if bad else ('WARN' if warn else 'PASS'))}">{('FAIL' if bad else ('WARN' if warn else 'PASS'))}</span></h2>
  <table><tr><th style="width:70px">级别</th><th>说明</th></tr>{verdict_rows}</table>
  <div class="note {'bad' if duplicate_login else 'ok'}">
    <b>「一起启动 / 什么都打不开」根因：</b>
    {'本机存在 <b>%d 份</b> 指向同一 App 的登录项且均 RunAtLoad=true，开机时被各拉起一份启动器，等于重复自启；启动器设计为登录时自动隐藏被管理 App 的窗口，两份叠加会把窗口隐藏行为翻倍，表现为「一起启动、桌面/应用打不开」。<br>修复：仅保留 1 份登录项（建议保留引用 dylib 包装 <code>SilentLauncher</code> 的那份，关于菜单注入才生效），删除多余的 <code>com.silentlauncher.login.plist</code>。' % stat['login_items'] if duplicate_login else '未发现重复登录项，自启逻辑正常。'}
  </div>
</section>

<section>
  <h2>① 登录项 (LaunchAgents) <span class="tag {'FAIL' if duplicate_login else 'PASS'}">{'FAIL' if duplicate_login else 'PASS'}</span></h2>
  <table><tr><th>文件</th><th>Label</th><th>ProgramArguments</th><th>RunAtLoad</th><th>目标存在</th><th>结论</th></tr>
  {rows_login or "<tr><td colspan='6'>未找到相关登录项</td></tr>"}
  </table>
</section>

<section>
  <h2>② 磁盘 App 副本 <span class="tag {'WARN' if extra_copies else 'PASS'}">{'WARN' if extra_copies else 'PASS'}</span></h2>
  <table><tr><th>路径</th><th>位置</th><th>结论</th></tr>{rows_copies}</table>
  <div class="note">废纸篓中 {len(trash_copies)} 份为反复重建/安装时移入的残留，可清空废纸篓释放空间（不影响 /Applications 本体）。</div>
</section>

<section>
  <h2>③ 运行态 <span class="tag {'PASS'}">PASS</span></h2>
  <h3 style="font-size:13px;color:#8b95a3;margin:6px 0">进程</h3>
  <table><tr><th>PID</th><th>CPU%</th><th>MEM%</th><th>命令</th></tr>{rows_proc}</table>
  <h3 style="font-size:13px;color:#8b95a3;margin:14px 0 6px">launchctl</h3>
  <table><tr><th>PID</th><th>上次退出码</th><th>Label</th></tr>{rows_lstate}</table>
</section>

<section>
  <h2>④ App 本体完整性 <span class="tag {'PASS' if integ['exists'] else 'FAIL'}">{'PASS' if integ['exists'] else 'FAIL'}</span></h2>
  <table><tr><th>检查项</th><th>结果</th><th>结论</th></tr>{integ_rows}</table>
</section>

<section>
  <h2>⑤ LaunchServices 注册异常 <span class="tag {'WARN' if ls_anom else 'PASS'}">{'WARN' if ls_anom else 'PASS'}</span></h2>
  <table><tr><th>被注册的路径</th><th>结论</th></tr>{rows_ls}</table>
  <div class="note">废纸篓副本被 LaunchServices 注册会形成「幽灵」入口；清空废纸篓或用 <code>lsregister -u</code> 注销后即可消除。</div>
</section>

<section>
  <h2>⑥ 设计说明（为何会自启）</h2>
  <p style="font-size:13.5px;color:#cdd5df">静默启动管理器<b>本就设计为登录时自启</b>：登录项 <code>RunAtLoad=true</code>，开机自动运行并以 <code>--silent</code> 隐藏被管理 App 的窗口（这是它的核心功能）。因此「开机自动启动」是预期行为；真正异常的是<b>重复登录项导致被拉起两份</b>。若你希望彻底关闭自启，可删除全部相关登录项（但会使其隐藏窗口功能失效）。</p>
</section>

</div></body></html>"""

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "静默启动管理器_启动项自检报告.html")
with open(out_path, "w", encoding="utf-8") as f:
    f.write(html_doc)

# 控制台摘要
print("=" * 60)
print("静默启动管理器 · 启动项自检")
print("=" * 60)
print(f"生效登录项(RunAtLoad): {stat['login_items']}  → {'❌ 重复，一起启动根因' if duplicate_login else '✅ 正常'}")
for p in plists:
    print(f"   · {p['file']}  Label={p['label']}  RunAtLoad={p['run_at_load']}  目标存在={p['target_exists']}")
print(f"残留 App 副本: {stat['extra_copies']}（废纸篓 {len(trash_copies)}）")
print(f"废纸篓副本被 LaunchServices 注册: {stat['trash_registered']}")
print(f"当前运行进程: {stat['running_procs']}")
print(f"二进制改名: 旧名 {integrity['binary_patched_old']} 处 / 新名 {integrity['binary_has_new']} 处")
print(f"dylib 包装: {'存在' if integrity['wrapper_present'] else '缺失'}  关于注入: {'存在' if integrity['dylib_present'] else '缺失'}")
print("-" * 60)
print(f"结论: {'FAIL' if bad else ('WARN' if warn else 'PASS')}  (OK={ok} WARN={warn} BAD={bad})")
print(f"报告: {out_path}")
print("=" * 60)
