#!/usr/bin/env python3
"""带 selref 注释的 arm64 方法反汇编(需要 pip install capstone)。

用法:
  python hdis.py <binary> <类名> <选择器正则> [指令条数]

用于核对 objc_dump.py 找到的方法内部逻辑(参数怎么用、调了什么选择器)。
抖音 40.6.0 上验证过 AWEIMMessageListSendMessageComponent sendMessage: 的
尾调链与参数属性(content/userInfo/quotedMessageId/trackParams)。

注意:capstone 对 adrp 输出的已是解析后的绝对页地址,直接用,不要再加 PC 页基址;
ldr 的 op_str 用正则提取 [xN, #imm],不要按 ", " split(操作数里也有逗号)。
"""
import struct, sys, mmap, re
from capstone import *

PATH = sys.argv[1]
CLS = sys.argv[2]
SEL_PAT = re.compile(sys.argv[3] if len(sys.argv) > 3 else ".*")
COUNT = int(sys.argv[4]) if len(sys.argv) > 4 else 120

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
            break
assert u32(base) == 0xfeedfacf
segs, sects = [], {}
ncmds = u32(base+16)
off = base + 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", mm, off)
    if cmd == 0x19:
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
    for n, va, vs, fo, fs in segs:
        if va <= addr < va + vs:
            return fo + (addr - va)
    return None
def file2vm(fo):
    for n, va, vs, ffo, fs in segs:
        if ffo <= fo < ffo + fs:
            return va + (fo - ffo)
    return None
def cstr_vm(addr, maxn=300):
    fo = vm2file(addr)
    if fo is None: return None
    end = mm.find(b"\0", fo, fo+maxn)
    if end < 0: return None
    try: return mm[fo:end].decode("utf-8", "replace")
    except Exception: return None

def chained_ptr_candidates(raw):
    """Yield plausible VM addresses from a chained-fixup pointer slot."""
    yield raw & 0xFFFFFFFFFF  # low 36 bits
    yield raw & 0xFFFFFFFFF
    high8 = (raw >> 36) & 0xFFFF
    yield ((high8 << 40) | (raw & 0xFFFFFFFFF))
    yield raw & 0x7FFFFFFFFFFF

def ptr_in_section(addr, secnames):
    for sn in secnames:
        if sn in sects:
            a, s = sects[sn]
            if a <= addr < a + s:
                return True
    return False

def ref_lookup(addr):
    for secname in ("__objc_selrefs", "__objc_classrefs", "__objc_superrefs", "__objc_ivar"):
        if secname in sects:
            a, s = sects[secname]
            if a <= addr < a + s and (addr - a) % 8 == 0:
                raw = u64(vm2file(addr))
                for cand in chained_ptr_candidates(raw):
                    if ptr_in_section(cand, ("__objc_methname", "__objc_classname", "__cstring", "__objc_methtype")):
                        nm = cstr_vm(cand)
                        if nm:
                            return f"{secname}:{nm}"
                nm = cstr_vm(raw)
                if nm: return f"{secname}:{nm}"
    return None

def read_methods(ml_fo):
    if not ml_fo: return []
    ef = u32(ml_fo); count = u32(ml_fo+4); entsize = ef & 0xFFFF
    rel = bool(ef & 0x80000000)
    out = []
    for i in range(count):
        e = ml_fo + 8 + i*entsize
        if rel:
            sel_vm = file2vm(e) + i32(e)
            sel = cstr_vm(u64(vm2file(sel_vm)))
            imp_vm = file2vm(e+8) + i32(e+8)
        else:
            sel = cstr_vm(u64(e)); imp_vm = u64(e+16)
        out.append((sel, imp_vm))
    return out

_a, _s = sects["__objc_classlist"]
cl_f, cl_n = vm2file(_a), _s
targets = []
for i in range(cl_n // 8):
    cls_vm = u64(cl_f + i*8)
    fo = vm2file(cls_vm)
    if fo is None: continue
    bits = u64(fo+32)
    ro_fo = vm2file(bits & ~7)
    if not ro_fo: continue
    name = cstr_vm(u64(ro_fo+0x18))
    if name != CLS: continue
    ml = u64(ro_fo+0x20)
    for sel, imp in read_methods(vm2file(ml)):
        if sel and re.search(SEL_PAT, sel) and imp:
            targets.append((sel, imp))

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True
for sel, imp in targets:
    print(f"\n==== {CLS} {sel}  @ {hex(imp)} ====")
    fo = vm2file(imp)
    code = mm[fo:fo+COUNT*4]
    regs = {}
    for ins in md.disasm(code, imp):
        line = f"  {hex(ins.address)}: {ins.mnemonic} {ins.op_str}"
        note = ""
        if ins.mnemonic == "adrp":
            parts = ins.op_str.split(", ")
            r = parts[0]; imm = int(parts[1].lstrip("#"), 16)
            regs[r] = imm  # capstone already resolves adrp to absolute page address
        elif ins.mnemonic == "add" and len(ins.operands) == 3:
            parts = ins.op_str.split(", ")
            if len(parts) == 3 and parts[0] == parts[1] and parts[2].startswith("#"):
                if parts[0] in regs:
                    try: regs[parts[0]] = regs[parts[0]] + int(parts[2][1:], 0)
                    except ValueError: pass
        elif ins.mnemonic == "ldr":
            m2 = re.search(r"\[(\w+)(?:,\s*#?(-?\w+))?\]", ins.op_str)
            if m2 and m2.group(1) in regs:
                try:
                    imm = int(m2.group(2), 0) if m2.group(2) else 0
                except ValueError:
                    imm = 0
                addr = regs[m2.group(1)] + imm
                r = ref_lookup(addr)
                if r: note = f"   ; {r}"
        if ins.mnemonic in ("bl", "b"):
            try:
                tgt = ins.operands[0].imm
                note += f"   ; -> {hex(tgt)}"
            except Exception:
                pass
        print(line + note)
        if ins.mnemonic == "ret":
            break
