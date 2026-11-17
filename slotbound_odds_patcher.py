#!/usr/bin/env python3
"""
Slotbound 稀有度概率 Mod 打包器（适配 v1.0.0(9)）
作者：TokioKaze

用法：
  python slotbound_odds_patcher.py <游戏目录>              # 安装 / 更新
  python slotbound_odds_patcher.py <游戏目录> --restore    # 恢复原版
  python slotbound_odds_patcher.py <游戏目录> --status     # 检查安装状态
图形界面见 SlotboundOddsModInstaller.py（可用 PyInstaller 打包成免 Python 的 EXE）。

做了什么：
  1. 用 Slotbound.exe 推导包密钥，解密 Slotbound.dat（AES-256-GCM），逐文件校验 SHA256。
  2. 把 src/game/luck.lua 替换为一个很小的 LuaJIT 字节码加载器：
       loadstring(Mod源码)(原luck字节码, ...)；Mod 源码加载失败则直接运行原 luck 模块。
  3. 更新游戏自带的完整性清单 src/release_integrity_manifest.bin 中 luck.lua 的哈希/大小，
     并把 src/release_integrity.lua 中内嵌的清单哈希改成新值（等长字符串替换）。
  4. 重新加密整个包（同一个主密钥），再完整解密一遍逐项核对加载器的全部校验规则。
需要：Python 3.8+，pip install cryptography
"""
import argparse, hashlib, hmac, os, struct, sys

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    sys.exit("缺少 cryptography 库，请先运行：pip install cryptography")

MAGIC = b"SBDAT008"
IDX_MAGIC = b"SBIDX006"
MARKER = b"SlotboundOddsMod"
TARGET = "src/game/luck.lua"
MANIFEST = "src/release_integrity_manifest.bin"
INTEGRITY = "src/release_integrity.lua"
# Slotbound.exe .data 中三个 32 字节密钥片段的 RVA（随 exe 版本变化）
KEY_RVAS = (0x22008, 0x22028, 0x22048)


# ---------------------------------------------------------------- PE / 密钥
def rva_to_off(exe, rva):
    pe = struct.unpack_from("<I", exe, 0x3C)[0]
    nsec = struct.unpack_from("<H", exe, pe + 6)[0]
    opt = struct.unpack_from("<H", exe, pe + 20)[0]
    sec = pe + 24 + opt
    for i in range(nsec):
        vsz, va, rawsz, raw = struct.unpack_from("<IIII", exe, sec + 40 * i + 8)
        if va <= rva < va + max(vsz, rawsz):
            return raw + (rva - va)
    raise ValueError("RVA 不在任何节中")


def master_key(exe, dat):
    g = [exe[rva_to_off(exe, r):rva_to_off(exe, r) + 32] for r in KEY_RVAS]
    sec = bytes(a ^ b for a, b in zip(g[0], g[1]))
    return hashlib.sha256(sec + hashlib.sha256(exe).digest() + dat[0x18:0x38] + g[2]).digest()


# ---------------------------------------------------------------- 解包
def unpack(exe, dat):
    if dat[:8] != MAGIC or dat[-0x38:] != dat[:0x38]:
        raise ValueError("Slotbound.dat 头/尾不符合 SBDAT008 格式（游戏可能已更新）")
    exe_size, payload = struct.unpack_from("<QQ", dat, 8)
    if exe_size != len(exe):
        raise ValueError("Slotbound.dat 记录的 exe 大小与当前 Slotbound.exe 不一致")
    if payload + 0x8C != len(dat):
        raise ValueError("Slotbound.dat 大小字段不一致")
    m = master_key(exe, dat)
    L = struct.unpack_from("<I", dat, 0x54)[0]
    aad = dat[:0x38] + dat[0x54:0x58]
    try:
        idx = AESGCM(hmac.new(m, b"slotbound:index:v6", hashlib.sha256).digest()).decrypt(
            dat[0x38:0x44], dat[0x58:0x58 + L] + dat[0x44:0x54], aad)
    except Exception:
        raise ValueError("索引解密失败：密钥不匹配（exe 或 dat 不是 v1.0.0(9) 原版，或已损坏）")
    if idx[:8] != IDX_MAGIC or struct.unpack_from("<I", idx, 12)[0] != 0:
        raise ValueError("索引格式不符")
    n = struct.unpack_from("<I", idx, 8)[0]
    base = 0x58 + L
    data_region = dat[base:len(dat) - 0x38]
    if hashlib.sha256(data_region).digest() != idx[-32:]:
        raise ValueError("数据区 SHA256 与索引不符")
    files, p, expect_off, prev = [], 16, 0, None
    for i in range(n):
        nl = struct.unpack_from("<H", idx, p)[0]
        rec = idx[p:p + nl + 0x3E]
        name = rec[2:2 + nl]
        off, sz = struct.unpack_from("<QQ", rec, 2 + nl)
        nonce, h = rec[nl + 0x12:nl + 0x1E], rec[nl + 0x1E:nl + 0x3E]
        if off != expect_off:
            raise ValueError("文件偏移不连续：%r" % name)
        if i == 0 and name != b"@bootstrap":
            raise ValueError("第一个条目不是 @bootstrap")
        if prev is not None and not prev < name:
            raise ValueError("文件名未严格递增：%r" % name)
        blob = data_region[off:off + 16 + sz]
        k = hmac.new(m, b"slotbound:file:v6" + rec, hashlib.sha256).digest()
        pt = AESGCM(k).decrypt(nonce, blob[16:] + blob[:16], rec)
        if hashlib.sha256(pt).digest() != h:
            raise ValueError("文件哈希不符：%r" % name)
        files.append((name.decode(), pt))
        p += nl + 0x3E
        expect_off += 16 + sz
        prev = name
    if p != len(idx) - 32 or expect_off != len(data_region):
        raise ValueError("索引/数据区长度不符")
    if not (6 <= len(files[0][1]) <= 0x100000):
        raise ValueError("@bootstrap 大小异常")
    return m, files


# ---------------------------------------------------------------- 打包
def repack(dat_template, m, files):
    hdr_salt = dat_template[0x18:0x38]
    exe_size = struct.unpack_from("<Q", dat_template, 8)[0]
    entries, blobs, off = [], [], 0
    for name, pt in files:
        nb = name.encode()
        nonce = os.urandom(12)
        rec = struct.pack("<H", len(nb)) + nb + struct.pack("<QQ", off, len(pt)) + nonce + hashlib.sha256(pt).digest()
        k = hmac.new(m, b"slotbound:file:v6" + rec, hashlib.sha256).digest()
        ct = AESGCM(k).encrypt(nonce, pt, rec)  # ct || tag
        blobs.append(ct[-16:] + ct[:-16])
        entries.append(rec)
        off += 16 + len(pt)
    data_region = b"".join(blobs)
    idx = IDX_MAGIC + struct.pack("<II", len(files), 0) + b"".join(entries) + hashlib.sha256(data_region).digest()
    L = len(idx)
    hdr = MAGIC + struct.pack("<QQ", exe_size, 4 + L + len(data_region)) + hdr_salt
    nonce = os.urandom(12)
    ik = hmac.new(m, b"slotbound:index:v6", hashlib.sha256).digest()
    ct = AESGCM(ik).encrypt(nonce, idx, hdr + struct.pack("<I", L))
    return b"".join([hdr, nonce, ct[-16:], struct.pack("<I", L), ct[:-16], data_region, hdr])


# ---------------------------------------------------------------- LuaJIT 字节码加载器
OPS = ("ISLT ISGE ISLE ISGT ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC ISFC IST ISF ISTYPE ISNUM "
       "MOV NOT UNM LEN ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV "
       "MODVV POW CAT KSTR KCDATA KSHORT KNUM KPRI KNIL UGET USETV USETS USETN USETP UCLO FNEW TNEW TDUP GGET "
       "GSET TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR CALLM CALL CALLMT CALLT ITERC ITERN VARG "
       "ISNEXT RETM RET RET0 RET1").split()
OP = {n: i for i, n in enumerate(OPS)}
OP["JMP"] = OPS.index("RET1") + 1 + 11  # FORI..JLOOP 共 11 条之后是 JMP


def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); return bytes(out)


def build_stub(mod_src: bytes, orig: bytes) -> bytes:
    # 常量（D 编号）：0='loadstring' 1=Mod源码 2=块名 3=原字节码
    consts = [b"loadstring", mod_src, b"=SlotboundOddsMod", orig]
    def AD(op, a, d): return OP[op] | a << 8 | d << 16
    def ABC(op, a, b, c): return OP[op] | a << 8 | c << 16 | b << 24
    bc = [
        AD("GGET", 0, 0),             # 0  r0 = loadstring
        AD("KSTR", 2, 1),             # 1  r2 = mod source
        AD("KSTR", 3, 2),             # 2  r3 = chunk name
        ABC("CALL", 0, 2, 3),         # 3  r0 = loadstring(r2, r3)
        AD("ISF", 0, 0),              # 4  if not r0 then
        AD("JMP", 1, 0x8000 + 3),     # 5      goto 9
        AD("KSTR", 2, 3),             # 6  r2 = original bytecode
        ABC("VARG", 3, 0, 0),         # 7  r3.. = ...
        AD("CALLMT", 0, 1),           # 8  return r0(r2, ...)
        AD("GGET", 0, 0),             # 9  r0 = loadstring
        AD("KSTR", 2, 3),             # 10 r2 = original bytecode
        ABC("CALL", 0, 2, 2),         # 11 r0 = loadstring(r2)
        ABC("VARG", 2, 0, 0),         # 12 r2.. = ...
        AD("CALLMT", 0, 0),           # 13 return r0(...)
    ]
    body = bytearray([0x02, 0, 8, 0])  # flags=VARARG, numparams=0, framesize=8, sizeuv=0
    body += uleb(len(consts)) + uleb(0) + uleb(len(bc))
    body += b"".join(struct.pack("<I", i) for i in bc)
    for c in reversed(consts):  # 读取顺序：最后读入的是 D=0
        body += uleb(len(c) + 5) + c
    return b"\x1bLJ\x02\x0a" + uleb(len(body)) + bytes(body) + b"\x00"


# ---------------------------------------------------------------- 主流程
def patch(files, mod_src):
    """替换 luck.lua，并沿着游戏的哈希链（清单 -> release_integrity.lua -> main.lua ...）
    自动把所有引用旧哈希的位置改成新哈希，直到不再变化。"""
    d = dict(files)
    luck = d[TARGET]
    if MARKER in luck:
        raise ValueError("Slotbound.dat 已经打过补丁。请用备份的原版 Slotbound.dat 重新打包")
    if luck[:3] != b"\x1bLJ" or luck[4] != 0x0A:
        raise ValueError("luck.lua 不是预期的 LuaJIT 字节码（游戏可能已更新）")
    stub = build_stub(mod_src, luck)

    # 1) 清单中 luck.lua 一行（哈希 + 大小）
    man = d[MANIFEST]
    old_line = hashlib.sha256(luck).hexdigest().encode() + b"\t" + str(len(luck)).encode() + b"\t" + TARGET.encode()
    if man.count(old_line) != 1:
        raise ValueError("完整性清单中找不到 luck.lua 条目（游戏可能已更新）")
    new_line = hashlib.sha256(stub).hexdigest().encode() + b"\t" + str(len(stub)).encode() + b"\t" + TARGET.encode()
    cur = dict(d)
    cur[TARGET] = stub
    cur[MANIFEST] = man.replace(old_line, new_line)

    # 2) 沿哈希链传播：某文件内容变了，所有以十六进制/原始字节形式包含它旧哈希的文件都要更新
    chain = []
    pending = [MANIFEST]
    seen = set()
    while pending:
        name = pending.pop(0)
        old_hex = hashlib.sha256(d[name]).hexdigest().encode()
        old_raw = hashlib.sha256(d[name]).digest()
        new_hex = hashlib.sha256(cur[name]).hexdigest().encode()
        new_raw = hashlib.sha256(cur[name]).digest()
        for other in cur:
            if other == name:
                continue
            c = cur[other]
            n = c.count(old_hex) + c.count(old_hex.upper()) + c.count(old_raw)
            if n:
                c = c.replace(old_hex, new_hex).replace(old_hex.upper(), new_hex.upper()).replace(old_raw, new_raw)
                cur[other] = c
                chain.append("%s 中引用 %s 的哈希 x%d" % (other, name, n))
                if other in seen and other != MANIFEST:
                    raise ValueError("哈希链出现循环：" + other)
                seen.add(other)
                pending.append(other)
    # 3) 自检：原包中被任何文件引用过哈希的文件，若内容已变，则旧哈希不得残留
    changed = [n for n in cur if cur[n] != d[n]]
    for name in changed:
        old_hex = hashlib.sha256(d[name]).hexdigest().encode()
        old_raw = hashlib.sha256(d[name]).digest()
        for other, c in cur.items():
            if old_hex in c or old_hex.upper() in c or old_raw in c:
                raise ValueError("自检失败：%s 仍包含 %s 的旧哈希" % (other, name))
    out = [(name, cur[name]) for name, _ in files]
    return out, {"stub": stub, "changed": changed, "chain": chain}


class PatchError(Exception):
    """给玩家看的错误（文字可直接显示）。"""


def resource_path(name):
    """查找随程序分发的资源：PyInstaller 打包后在 sys._MEIPASS / exe 旁边，源码运行时在脚本旁边。"""
    cands = []
    if getattr(sys, "frozen", False):
        if getattr(sys, "_MEIPASS", None):
            cands.append(sys._MEIPASS)
        cands.append(os.path.dirname(os.path.abspath(sys.executable)))
    cands.append(os.path.dirname(os.path.abspath(__file__)))
    for d in cands:
        q = os.path.join(d, name)
        if os.path.isfile(q):
            return q
    raise PatchError("找不到随安装器分发的文件 %s（请完整解压压缩包后再运行）" % name)


class Pack(object):
    """一个 .dat 文件相对当前 Slotbound.exe 的状态：missing / original / modded / invalid。"""
    def __init__(self, exe, path):
        self.path, self.kind, self.err = path, "missing", ""
        self.data = self.m = self.files = self.sha = None
        if not os.path.isfile(path):
            return
        self.data = open(path, "rb").read()
        self.sha = hashlib.sha256(self.data).hexdigest()
        try:
            self.m, self.files = unpack(exe, self.data)
            self.kind = "modded" if MARKER in dict(self.files)[TARGET] else "original"
        except Exception as e:  # 解不开 = 与当前 exe 版本不匹配，或文件损坏
            self.kind, self.err = "invalid", str(e)

KIND_CN = {"missing": "不存在", "original": "原版（与当前游戏版本匹配）", "modded": "已安装 Mod",
           "invalid": "无法解密（与当前游戏版本不匹配或已损坏）"}


def _read_exe(game_dir):
    p = os.path.join(game_dir, "Slotbound.exe")
    if not os.path.isfile(p):
        raise PatchError("这个文件夹里没有 Slotbound.exe，请选择游戏安装目录。\n"
                         "（Steam 库里右键 Slotbound → 管理 → 浏览本地文件）")
    return open(p, "rb").read()


def _write_atomic(data, dest):
    """先完整写到临时文件并落盘，再一步替换；任何一步失败都不会动 dest。"""
    tmp = dest + ".new"
    try:
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, dest)
    except PermissionError:
        _rm(tmp)
        raise PatchError("无法写入 %s：文件被占用或没有权限。请先关闭游戏再试。原文件未被改动。" % os.path.basename(dest))
    except OSError as e:
        _rm(tmp)
        raise PatchError("写入 %s 失败（%s）。请检查磁盘空间。原文件未被改动。" % (os.path.basename(dest), e))


def _rm(path):
    try:
        os.remove(path)
    except OSError:
        pass


def build_patched(exe, src, mod_src, log=print):
    """src: 原版 Pack。返回打好补丁并完整回读校验过的新包字节。"""
    if MARKER not in mod_src:
        raise PatchError("Mod 源码文件不对（SlotboundOddsMod.lua）")
    files, m, dat = src.files, src.m, src.data
    log("解密并校验 %d 个文件：通过" % len(files))
    new_files, info = patch(files, mod_src)
    new_dat = repack(dat, m, new_files)
    m2, chk = unpack(exe, new_dat)
    assert m2 == m and [n for n, _ in chk] == [n for n, _ in files]
    cd = dict(chk)
    assert cd[TARGET] == info["stub"]
    for (n, a_), (_, b_) in zip(files, chk):
        if n not in info["changed"]:
            assert a_ == b_, n
    man = cd[MANIFEST]
    assert hashlib.sha256(man).hexdigest().encode() in cd[INTEGRITY]
    assert hashlib.sha256(cd[INTEGRITY]).hexdigest().encode() in cd["main.lua"]
    for line in man.split(b"\n")[2:]:
        if not line: continue
        h, sz, name = line.split(b"\t")
        pt = cd[name.decode()]
        assert hashlib.sha256(pt).hexdigest().encode() == h and int(sz) == len(pt), name
    log("改动的文件：" + ", ".join(info["changed"]))
    log("新包回读校验：通过（索引、GCM 标签、逐文件 SHA256、完整性清单 %d 项）" % (len(man.split(b"\n")) - 2))
    return new_dat


def install(game_dir, mod_path=None, log=print, out=None, dat=None):
    """安装/更新。任何失败都保证游戏目录里的 Slotbound.dat 保持安装前的内容。"""
    exe = _read_exe(game_dir)
    game_dat = os.path.join(game_dir, "Slotbound.dat")
    backup = game_dat + ".orig"
    mod_src = open(mod_path or resource_path("SlotboundOddsMod.lua"), "rb").read()
    if dat:  # 开发用：指定原版包
        src = Pack(exe, dat)
        if src.kind != "original":
            raise PatchError("指定的包不是当前版本的原版：" + (src.err or KIND_CN[src.kind]))
        need_backup = False
    else:
        cur, bak = Pack(exe, game_dat), Pack(exe, backup)
        log("当前 Slotbound.dat：" + KIND_CN[cur.kind])
        log("备份 Slotbound.dat.orig：" + KIND_CN[bak.kind])
        if cur.kind == "original":
            # 当前文件就是这个游戏版本的原版：以它为准；旧备份若不一致（例如游戏更新前留下的）就换掉
            src = cur
            need_backup = not (bak.kind == "original" and bak.sha == cur.sha)
            if need_backup and bak.kind != "missing":
                log("旧备份与当前游戏版本不一致（可能是游戏更新前留下的），将用当前原版重新备份")
        elif bak.kind == "original":
            src, need_backup = bak, False
            log("使用已校验的备份作为原版")
        elif cur.kind == "missing":
            raise PatchError("游戏目录里没有 Slotbound.dat。请在 Steam 里“验证游戏文件的完整性”后重试。")
        elif cur.kind == "modded":
            raise PatchError("当前已安装 Mod，但找不到与当前游戏版本匹配的原版备份（%s）。\n"
                             "请在 Steam 里右键 Slotbound → 属性 → 已安装文件 → “验证游戏文件的完整性”，然后重新安装。\n"
                             "没有改动任何文件。" % KIND_CN[bak.kind])
        else:
            raise PatchError("无法解密 Slotbound.dat：%s\n"
                             "本 Mod 只适配游戏 v1.0.0(9)。如果游戏刚更新过，需要等 Mod 适配新版本；\n"
                             "如果文件损坏，请在 Steam 里“验证游戏文件的完整性”。没有改动任何文件。" % cur.err)
    try:
        new_dat = build_patched(exe, src, mod_src, log)
    except PatchError:
        raise
    except Exception as e:
        raise PatchError("打补丁失败（%s: %s）。游戏版本可能与 Mod 不匹配。没有改动任何文件。" % (type(e).__name__, e))
    if out:
        _write_atomic(new_dat, out)
        log("已写入：" + out)
        return
    if need_backup:
        _write_atomic(src.data, backup)  # 复制而不是移动：此时 Slotbound.dat 仍在原位
        log("已备份原版：" + backup)
    _write_atomic(new_dat, game_dat)
    if hashlib.sha256(open(game_dat, "rb").read()).digest() != hashlib.sha256(new_dat).digest():
        raise PatchError("写入后校验不一致，请运行“恢复原版”。")
    log("已写入：" + game_dat)
    ini = os.path.join(game_dir, "SlotboundOddsMod.ini")
    if not os.path.exists(ini):
        try:
            open(ini, "wb").write(open(resource_path("SlotboundOddsMod.ini"), "rb").read())
            log("已放入默认配置：" + ini)
        except (PatchError, OSError):
            log("（未放入默认配置文件，不影响使用：游戏内 F8 面板可直接调整并保存）")
    else:
        log("保留已有配置：" + ini)
    log("安装成功。之后直接从 Steam 启动游戏即可，无需再运行本工具。")


def restore(game_dir, log=print):
    """恢复原版：只有在备份通过校验（能用当前 exe 解密、且不含 Mod）时才覆盖。"""
    exe = _read_exe(game_dir)
    game_dat = os.path.join(game_dir, "Slotbound.dat")
    cur, bak = Pack(exe, game_dat), Pack(exe, game_dat + ".orig")
    log("当前 Slotbound.dat：" + KIND_CN[cur.kind])
    log("备份 Slotbound.dat.orig：" + KIND_CN[bak.kind])
    if cur.kind == "original":
        log("当前已经是原版，无需恢复。")
        return
    if bak.kind != "original":
        raise PatchError("备份 Slotbound.dat.orig %s，不能用它恢复（游戏更新后旧备份会失效）。\n"
                         "请在 Steam 里右键 Slotbound → 属性 → 已安装文件 → “验证游戏文件的完整性”来恢复原版。\n"
                         "没有改动任何文件。" % KIND_CN[bak.kind])
    _write_atomic(bak.data, game_dat)
    log("已恢复原版 Slotbound.dat（备份保留，方便以后重新安装）。")


def status(game_dir, log=print):
    exe = _read_exe(game_dir)
    game_dat = os.path.join(game_dir, "Slotbound.dat")
    cur, bak = Pack(exe, game_dat), Pack(exe, game_dat + ".orig")
    log("游戏目录：" + game_dir)
    log("Slotbound.dat：" + KIND_CN[cur.kind] + (("  " + cur.err) if cur.err else ""))
    log("Slotbound.dat.orig：" + KIND_CN[bak.kind])
    if cur.kind == "modded":
        try:
            src = dict(cur.files)[TARGET]
            k = src.find(b'MOD_VERSION = "')
            if k >= 0:
                log("已安装的 Mod 版本：" + src[k + 15:src.index(b'"', k + 15)].decode())
        except Exception:
            pass
        log("结论：Mod 已安装。" + ("" if bak.kind == "original" else "注意：没有可用备份，恢复原版需用 Steam 验证完整性。"))
    elif cur.kind == "original":
        log("结论：当前是原版，Mod 未安装。")
    elif cur.kind == "invalid":
        log("结论：游戏版本与本 Mod 不匹配（只适配 v1.0.0(9)），或文件已损坏。")
    else:
        log("结论：找不到 Slotbound.dat。")
    return cur.kind


def main():
    ap = argparse.ArgumentParser(description="Slotbound 概率 Mod 安装器（命令行）")
    ap.add_argument("game_dir")
    ap.add_argument("--restore", action="store_true", help="恢复原版")
    ap.add_argument("--status", "--verify-only", dest="status", action="store_true", help="只检查安装状态")
    ap.add_argument("--mod", help="Mod 源码（默认用随程序分发的 SlotboundOddsMod.lua）")
    ap.add_argument("--dat", help="（开发用）指定原版 Slotbound.dat")
    ap.add_argument("--out", help="（开发用）输出到指定路径，不改动游戏目录")
    a = ap.parse_args()
    try:
        if a.status:
            status(a.game_dir)
        elif a.restore:
            restore(a.game_dir)
        else:
            install(a.game_dir, a.mod, out=a.out, dat=a.dat)
    except PatchError as e:
        print("[失败] " + str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
