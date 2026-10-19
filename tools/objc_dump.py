#!/usr/bin/env python3
"""Mach-O ObjC 元数据解析(Windows 上替代 class-dump)。

用法:
  python objc_dump.py <binary> classes  <类名正则>       # 列匹配的类
  python objc_dump.py <binary> methods  <选择器正则>     # 列含匹配方法的类
  python objc_dump.py <binary> types    <类名>           # 方法+类型编码
  python objc_dump.py <binary> ivt      <类名>           # ivar+类型编码
  python objc_dump.py <binary> dump     <类名>           # 全量 ivar+方法

抖音 40.6.0 用它定位了:
  AWEIMMessageListViewModel / AWEIMMessageListSendMessageComponent /
  AWEIMSendMessageContext / AWEIMMessageConversation / AWEIMTextMessage
主二进制极小,真正目标在 Aweme.app/Frameworks/AwemeCore.framework/AwemeCore(约1GB,thin arm64)。
"""
import struct, sys, mmap, re

PATH = sys.argv[1]
MODE = sys.argv[2] if len(sys.argv) > 2 else "methods"
ARG  = sys.argv[3] if len(sys.argv) > 3 else "sendTextMessage"

f = open(PATH, "rb")
mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

def u32(o): return struct.unpack_from("<I", mm, o)[0]
def u64(o): return struct.unpack_from("<Q", mm, o)[0]
def i32(o): return struct.unpack_from("<i", mm, o)[0]

magic = u32(0)
base, size = 0, len(mm)
if magic in (0xcafebabe, 0xcafebabf):
    nfat = u32(4)
    for i in range(nfat):
        cput, cpus, off, sz, al = struct.unpack_from("<IIIII", mm, 8 + i*20)
        if cput in (0x0100000C, 0x0200000C):
            base, size = off, sz
            print(f"# fat slice @ {base} size {size}", file=sys.stderr)
            break

MH_MAGIC_64 = 0xfeedfacf
assert u32(base) == MH_MAGIC_64, "not mach-o 64"

segs = []
sects = {}
ncmds = u32(base+16)
off = base + 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", mm, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = mm[off+8:off+24].rstrip(b"\0").decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", mm, off+24)
        segs.append((segname, vmaddr, vmsize, fileoff, filesize))
        nsects = u32(off+64)
        so = off + 72
        for s in range(nsects):
            sn = mm[so:so+16].rstrip(b"\0").decode()
            addr, ssize = struct.unpack_from("<QQ", mm, so+32)
            sects[sn] = (addr, ssize)
            so += 80
    off += cmdsize

def vm2file(addr):
    for segname, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= addr < vmaddr + vmsize:
            fo = fileoff + (addr - vmaddr)
            if fo < fileoff + filesize or segname == "__LINKEDIT":
                return fo
    return None

def file2vm(fo):
    for segname, vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= fo < fileoff + filesize:
            return vmaddr + (fo - fileoff)
    return None

def cstr_at_vm(addr, maxn=400):
    fo = vm2file(addr)
    if fo is None: return None
    end = mm.find(b"\0", fo, fo+maxn)
    if end < 0: return None
    try:
        return mm[fo:end].decode("utf-8", "replace")
    except Exception:
        return None

def sect_file(name):
    a, s = sects[name]
    return vm2file(a), s

classlist_f, classlist_n = sect_file("__objc_classlist")

def read_methods(ml_fo, want_types=False):
    """Return list of (selector, type_encoding) from a method_list_t at file offset."""
    if not ml_fo: return []
    entsize_flags = u32(ml_fo)
    count = u32(ml_fo+4)
    entsize = entsize_flags & 0xFFFF
    relative = bool(entsize_flags & 0x80000000)
    out = []
    for i in range(count):
        e = ml_fo + 8 + i*entsize
        try:
            if relative:
                tgt_fo = e + i32(e)
                ptr = u64(tgt_fo)          # selref slot -> VM addr of cstring
                if want_types:
                    field_fo = e + 4
                    field_vm = file2vm(field_fo)
                    typ = cstr_at_vm(field_vm + i32(field_fo)) if field_vm else None
            else:
                ptr = u64(e)
                if want_types:
                    typ = cstr_at_vm(u64(e+8))
            sel = cstr_at_vm(ptr)
            if sel: out.append((sel, typ if want_types else None))
        except Exception:
            pass
    return out

def read_ivars(iv_fo, want_types=False):
    if not iv_fo: return []
    entsize = u32(iv_fo) & 0xFFFF
    count = u32(iv_fo+4)
    out = []
    for i in range(count):
        e = iv_fo + 8 + i*entsize
        try:
            namep = u64(e+8)
            n = cstr_at_vm(namep)
            t = cstr_at_vm(u64(e+16)) if want_types else None
            if n: out.append((n, t) if want_types else n)
        except Exception:
            pass
    return out

def class_info2(cls_vm):
    fo = vm2file(cls_vm)
    if fo is None: return None
    bits = u64(fo+32)   # isa(8) super(8) cache(16)
    data = bits & 0xFFFFFFFFFFFFFFF8 if bits > 0 else 0
    ro_fo = vm2file(data)
    if not ro_fo: return None
    namep = u64(ro_fo+0x18)
    name = cstr_at_vm(namep)
    ml = u64(ro_fo+0x20)
    methods = read_methods(vm2file(ml), want_types=True) if ml else []
    ivp = u64(ro_fo+0x30)
    ivars = read_ivars(vm2file(ivp), want_types=True) if ivp else []
    return name, methods, ivars

if MODE == "classes":
    pat = re.compile(ARG)
    n = 0
    for i in range(classlist_n // 8):
        cls = u64(classlist_f + i*8)
        info = class_info2(cls)
        if not info: continue
        name, methods, ivars = info
        if name and pat.search(name):
            n += 1
            print(name)
    print(f"# {n} classes matched", file=sys.stderr)
elif MODE == "ivt":
    for i in range(classlist_n // 8):
        cls = u64(classlist_f + i*8)
        info = class_info2(cls)
        if not info: continue
        name, methods, ivars = info
        if name == ARG:
            print(f"== {name} ivars ==")
            for pair in ivars:
                if isinstance(pair, tuple):
                    print(f"  {pair[0]}: {pair[1]}")
                else:
                    print(f"  {pair}")
            break
elif MODE == "methods":
    pat = re.compile(ARG)
    seen = {}
    for i in range(classlist_n // 8):
        cls = u64(classlist_f + i*8)
        info = class_info2(cls)
        if not info: continue
        name, methods, ivars = info
        if not name: continue
        hits = sorted({m for m, t in methods if pat.search(m)})
        if hits:
            seen[name] = hits
    for k in sorted(seen):
        print(f"{k}: {', '.join(seen[k])}")
    print(f"# {len(seen)} classes", file=sys.stderr)
elif MODE == "types":
    for i in range(classlist_n // 8):
        cls = u64(classlist_f + i*8)
        info = class_info2(cls)
        if not info: continue
        name, methods, ivars = info
        if name == ARG:
            print(f"== {name} ==")
            for m, t in methods:
                print(f"  {m}    {t}")
            break
elif MODE == "dump":
    for i in range(classlist_n // 8):
        cls = u64(classlist_f + i*8)
        info = class_info2(cls)
        if not info: continue
        name, methods, ivars = info
        if name == ARG:
            print(f"== {name} ==")
            print("-- ivars:", ", ".join(p[0] if isinstance(p, tuple) else p for p in ivars))
            print("-- methods:")
            for m, t in methods:
                print("  ", m)
            break
