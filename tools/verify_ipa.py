#!/usr/bin/env python3
"""对任意抖音 IPA 复跑本插件的钩子面校验。

    python tools/verify_ipa.py <抖音.ipa> [--cache DIR] [--json]

判定标准不是"方法名在二进制里存在",而是:
  1) 类存在(出现在 __objc_classname);
  2) 该类**自身**的 method list 里实现了该方法。

第 2 条是硬要求:对"继承而来、本类未实现"的方法做 %hook,替换会落到超类的
Method 上,等于 hook 全 App 的同类调用(本项目 v2.15.0 的 -init 事故即由此而来)。

退出码:0 全部通过 / 1 有断裂 / 2 环境问题。
"""
import json
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "objc_dump.py")

# (类, [必须由该类自身实现的方法])
REQUIRED = [
    ("AWEIMMessageListViewModel",            ["setConversation:"]),
    ("AWEIMMessageListComponentCenter",      ["addComponent:", "addComponents:", "setComponents:"]),
    ("AWEIMMessageListSendMessageComponent", ["componentDidMounted:", "setDataService:",
                                              "sendMessage:mentionUsers:customToast:enterFrom:"]),
    ("AWEIMSendAttachmentController",        ["sendAttachmentMsgWithContext:completion:"]),
    ("AWEGeneralSettingViewController",      ["viewDidLoad"]),
    ("AWESettingsTableViewController",       ["viewDidAppear:"]),
]

# (类, 方法, 为什么必须保持"不实现")——这些是 40.7.0 复核出的坑,插件故意不钩
FORBIDDEN = [
    ("AWEIMMessageListSendMessageComponent", "init",
     "本类不实现 -init,钩它会打到超类(全 App init)"),
    ("AWESettingPageBaseController", "viewDidLoad",
     "本类不实现 viewDidLoad,钩它会打到 UIViewController 链"),
]

# 引擎用 KVC 读写的字段(属性或 ivar 均可,只要类型编码可读写)
# 注意字段归属:40.7.0 把 duration / averagePowerArr 放在 AWEIMMessageAudioContent
# 上,写成 IESIMSendAudioInputContext 的属性会抛 NSUnknownKeyException。
KV_FIELDS = {
    "AWEIMSendMessageContext":      ["content", "enterFrom", "userInfo", "mentionUsers"],
    "IESIMSendMediaInputContext":   ["conversationID", "tmpPath", "fileType",
                                     "messageType", "messageContent"],
    "IESIMSendAudioInputContext":   ["conversationID", "tmpPath", "fileType",
                                     "messageType", "messageContent"],
    "AWEIMMessageAudioContent":     ["duration", "averagePowerArr"],
    "AWEIMMessageImageContent":     ["coverWidth", "coverHeight", "clientKey"],
}


def pick_binaries(ipa):
    """返回 [(zip 内路径, 说明)],按体积从大到小。"""
    z = zipfile.ZipFile(ipa)
    names = z.namelist()
    out = []
    for n in names:
        if not n.startswith("Payload/") or "/Frameworks/" in n and n.count("/") != 3:
            pass
        base = n.rsplit("/", 1)[-1]
        if not n.endswith("/" + base):
            continue
        parent = n.rsplit("/", 1)[0].rsplit("/", 1)[-1]
        if parent.endswith(".framework") and base == parent[:-len(".framework")]:
            out.append((n, parent))
    out.sort(key=lambda p: z.getinfo(p[0]).file_size, reverse=True)
    if not out:
        sys.exit("IPA 里找不到 .framework 主二进制,结构异常")
    return z, out


def extract(z, member, cache):
    size = z.getinfo(member).file_size
    dst = os.path.join(cache, os.path.basename(member) + "." + re.sub(r"\W+", "_", member)[-24:])
    if os.path.exists(dst) and abs(os.path.getsize(dst) - size) < 1 << 20:
        return dst
    with z.open(member) as f, open(dst, "wb") as g:
        while True:
            b = f.read(1 << 22)
            if not b:
                break
            g.write(b)
    return dst


def class_methods(binary, cls):
    """返回 {方法名: 类型编码}；类不存在时返回 None。"""
    r = subprocess.run([sys.executable, DUMP, binary, "types", cls],
                       capture_output=True, text=True, errors="replace")
    text = r.stdout
    if "== %s ==" % cls not in text:
        return None
    methods = {}
    for line in text.splitlines():
        m = re.match(r"^ {2}(\S+)\s+(\S+)$", line)
        if m:
            methods[m.group(1)] = m.group(2)
    return methods


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    ipa = args[0]
    cache = os.path.join(HERE, "..", "_ipa_cache")
    if "--cache" in sys.argv:
        cache = sys.argv[sys.argv.index("--cache") + 1]
    cache = os.path.abspath(cache)
    os.makedirs(cache, exist_ok=True)

    z, cands = pick_binaries(ipa)
    info = {}
    try:
        import plistlib
        raw = z.read("Payload/Aweme.app/Info.plist") if "Payload/Aweme.app/Info.plist" in z.namelist() else None
        if raw:
            pl = plistlib.loads(raw)
            info = {k: pl.get(k) for k in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
    except Exception:
        pass
    print("IPA:", os.path.basename(ipa), info)

    # 目标类都在 AwemeCore；主二进制是薄壳。逐个候选探测，取第一个命中的。
    target = None
    for member, label in cands:
        path = extract(z, member, cache)
        probe = class_methods(path, REQUIRED[0][0])
        print("  探测 %-46s -> %s" % (label, "命中" if probe is not None else "无"))
        if probe is not None:
            target = path
            break
    if target is None:
        sys.exit("所有 framework 里都找不到 %s，无法校验" % REQUIRED[0][0])

    fail = 0
    print("\n[1] 必须由该类自身实现的方法")
    for cls, sels in REQUIRED:
        methods = class_methods(target, cls)
        if methods is None:
            print("  MISS 类不存在: %s" % cls)
            fail += len(sels)
            continue
        for sel in sels:
            ok = sel in methods
            fail += 0 if ok else 1
            print("  %-5s %s.%s%s" % ("PASS" if ok else "MISS", cls, sel,
                                      "" if ok else "   (类存在但无自身实现)"))

    print("\n[2] 必须保持不钩的坑(本类不应实现)")
    for cls, sel, why in FORBIDDEN:
        methods = class_methods(target, cls)
        own = bool(methods) and sel in methods
        print("  %-5s %s.%s%s" % ("PASS" if not own else "WARN", cls, sel,
                                  "" if not own else "   本类已实现,可安全加钩子?"))
        print("        理由: %s" % why)

    print("\n[3] 引擎 KVC 读写的字段")
    for cls, fields in KV_FIELDS.items():
        methods = class_methods(target, cls) or {}
        for f in fields:
            ok = f in methods or ("set" + f[:1].upper() + f[1:] + ":") in methods
            print("  %-5s %s.%s" % ("PASS" if ok else "MISS", cls, f))

    print("\n结论:", "全部通过" if fail == 0 else "%d 项断裂,插件需适配" % fail)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
