#!/usr/bin/env python3
"""把 pencil-handwriting.koplugin 的笔迹导出到 PDF / 图片。

插件把笔画存在文档的 sidecar 目录里：

    <书名>.sdr/pencil_handwriting.lua

其中 `space = "page"` 的笔画坐标就是**文档页面坐标**（PDF 即 1:1 的点，原点在页面左上）。
本脚本读取该文件，把笔迹画回 PDF，输出到指定文件夹。原文件不会被修改。

用法::

    # 最简：自动寻找 sidecar，输出到 <PDF 目录>/pencil-export/<书名>/
    python export_annotations.py --pdf "D:/books/某书.pdf"

    # 指定 sidecar 与输出目录
    python export_annotations.py --pdf a.pdf --sidecar a.sdr/pencil_handwriting.lua \\
        --out "D:/导出" --mode flatten

    # 每页导出 PNG（方便发到聊天或笔记软件）
    python export_annotations.py --pdf a.pdf --mode png --dpi 300

    # 只看报告，不写文件
    python export_annotations.py --pdf a.pdf --mode report

产出（`--out` 目录下，文件名带后缀，绝不覆盖原 PDF）：

    <书名>_annotated.pdf   原页面 + 笔迹（可直接分享、打印）
    <书名>_ink.pdf         只有笔迹的透明层（供其他工具叠加）
    pages/page-0001.png    每页渲染图（--mode png / all 时）

依赖：PyMuPDF（``pip install pymupdf``）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field

try:
    import pymupdf
except ImportError:  # pragma: no cover - older package name
    try:
        import fitz as pymupdf  # type: ignore
    except ImportError:
        sys.exit("需要 PyMuPDF：pip install pymupdf")

SIDECAR_NAME = "pencil_handwriting.lua"

# 与 pencilhw/config.lua 的 COLOR_PALETTE 对应（0..255 灰度）
COLORS = {
    "black": 0x00,
    "gray25": 0x40,
    "gray50": 0x80,
    "gray75": 0xC0,
    "white": 0xFF,
}


# ---------------------------------------------------------------------------
# 解析 sidecar（Lua 表）
# ---------------------------------------------------------------------------
class LuaTableParser:
    """只够解析 sidecar 的最小 Lua 表解析器。

    容忍注释、任意空白与字段顺序；遇到不认识的结构就报错，而不是猜。
    """

    def __init__(self, text: str):
        self.text = self._strip_comments(text)
        self.pos = 0

    @staticmethod
    def _strip_comments(text: str) -> str:
        out, i, n = [], 0, len(text)
        while i < n:
            c = text[i]
            if c == "-" and i + 1 < n and text[i + 1] == "-":
                # 长注释 --[[ ... ]] / --[=[ ... ]=]
                j = i + 2
                eq = 0
                if j < n and text[j] == "[":
                    k = j + 1
                    while k < n and text[k] == "=":
                        eq += 1
                        k += 1
                    if k < n and text[k] == "[":
                        closing = "]" + "=" * eq + "]"
                        end = text.find(closing, k + 1)
                        i = n if end == -1 else end + len(closing)
                        continue
                end = text.find("\n", i)
                i = n if end == -1 else end
                continue
            if c in ("'", '"'):
                quote, j = c, i + 1
                while j < n:
                    if text[j] == "\\":
                        j += 2
                        continue
                    if text[j] == quote:
                        break
                    j += 1
                out.append(text[i:j + 1])
                i = j + 1
                continue
            out.append(c)
            i += 1
        return "".join(out)

    def _skip_ws(self):
        while self.pos < len(self.text) and self.text[self.pos] in " \t\r\n":
            self.pos += 1

    def parse(self):
        self._skip_ws()
        # 跳过可选的 return
        if self.text.startswith("return", self.pos):
            self.pos += len("return")
        self._skip_ws()
        return self._value()

    def _value(self):
        self._skip_ws()
        if self.pos >= len(self.text):
            raise ValueError("意外的文件结尾")

        c = self.text[self.pos]
        if c == "{":
            return self._table()
        if c in ("'", '"'):
            return self._string()
        if c == "-" or c.isdigit():
            return self._number()
        if self.text.startswith("nil", self.pos):
            self.pos += 3
            return None
        if self.text.startswith("true", self.pos):
            self.pos += 4
            return True
        if self.text.startswith("false", self.pos):
            self.pos += 5
            return False
        raise ValueError("无法解析的位置 %d：%r" % (self.pos, self.text[self.pos:self.pos + 30]))

    def _string(self):
        quote = self.text[self.pos]
        i, n = self.pos + 1, len(self.text)
        out = []
        while i < n:
            c = self.text[i]
            if c == "\\" and i + 1 < n:
                nxt = self.text[i + 1]
                if nxt.isdigit():
                    # Lua 的 %q 把控制字符写成**十进制**转义（制表符是 "\9"，
                    # 换行是 "\10"），不是 "\t"/"\n"。当成字面量读会悄悄把带
                    # 这类字符的名字读错，而且不会有任何报错。
                    j, digits = i + 1, ""
                    while j < n and len(digits) < 3 and self.text[j].isdigit():
                        digits += self.text[j]
                        j += 1
                    out.append(chr(int(digits)))
                    i = j
                    continue
                if nxt == "x":
                    j, digits = i + 2, ""
                    while j < n and len(digits) < 2 and self.text[j] in "0123456789abcdefABCDEF":
                        digits += self.text[j]
                        j += 1
                    if digits:
                        out.append(chr(int(digits, 16)))
                        i = j
                        continue
                out.append({"n": "\n", "t": "\t", "r": "\r",
                            "a": "\a", "b": "\b", "f": "\f", "v": "\v",
                            '"': '"', "'": "'", "\\": "\\"}.get(nxt, nxt))
                i += 2
                continue
            if c == quote:
                break
            out.append(c)
            i += 1
        self.pos = i + 1
        return "".join(out)

    def _number(self):
        m = re.match(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", self.text[self.pos:])
        if not m:
            raise ValueError("非法数字：%r" % self.text[self.pos:self.pos + 20])
        raw = m.group(0)
        self.pos += len(raw)
        return float(raw) if ("." in raw or "e" in raw.lower()) else int(raw)

    def _table(self):
        self.pos += 1  # {
        array, mapping = [], {}
        while True:
            self._skip_ws()
            if self.pos >= len(self.text):
                raise ValueError("表没有闭合")
            if self.text[self.pos] == "}":
                self.pos += 1
                break

            if self.text[self.pos] == "[":
                self.pos += 1
                self._skip_ws()
                if self.text[self.pos] in ("'", '"'):
                    key = self._string()
                else:
                    key = self._number()
                self._skip_ws()
                if self.pos >= len(self.text) or self.text[self.pos] != "]":
                    raise ValueError("[key] 没有闭合")
                self.pos += 1
                self._skip_ws()
                if self.pos >= len(self.text) or self.text[self.pos] != "=":
                    raise ValueError("[key] 后面缺少 =")
                self.pos += 1
                mapping[key] = self._value()
            else:
                # 可能形如 `name = value`，也可能是数组项
                save = self.pos
                m = re.match(r"([A-Za-z_]\w*)\s*=", self.text[self.pos:])
                if m:
                    self.pos += m.end()
                    mapping[m.group(1)] = self._value()
                else:
                    self.pos = save
                    array.append(self._value())

            self._skip_ws()
            if self.pos < len(self.text) and self.text[self.pos] in ",;":
                self.pos += 1

        if array:
            # 数组与命名键混在一张表里：本文件不会出现，真出现就当数组
            return array
        return mapping


@dataclass
class Stroke:
    tool: str
    space: str
    width: float
    color: str
    points: list = field(default_factory=list)


def load_sidecar(path: str) -> dict:
    """读笔迹文件。`.lua`（设备上的原始文件）和 `.json`（菜单导出的那份）都行。"""
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if text.startswith("\ufeff"):        # 记事本另存的 BOM
        text = text[1:]

    if path.lower().endswith(".json") or text.lstrip()[:1] == "{":
        data = json.loads(text)
    else:
        data = LuaTableParser(text).parse()

    if not isinstance(data, dict):
        raise ValueError("sidecar 顶层不是表")
    version = data.get("version")
    if version not in (1, 2):
        raise ValueError("不支持的存储格式版本：%r" % (version,))

    pages = {}
    for key, entries in (data.get("pages") or {}).items():
        strokes = []
        for raw in entries or []:
            if not isinstance(raw, dict):
                continue
            strokes.append(Stroke(
                tool=str(raw.get("tool", "pen")),
                # 版本 1 的文件没有 space 字段：那时坐标是屏幕像素，无法映射到页面
                space=str(raw.get("space", "native")),
                width=float(raw.get("width", 3) or 3),
                color=str(raw.get("color", "black")),
                points=[float(v) for v in (raw.get("points") or [])],
            ))
        pages[key] = strokes

    doc = data.get("doc")
    return {"version": version, "pages": pages,
            "doc": doc if isinstance(doc, dict) else {}}


def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return "%d B" % n


def verify_document(sidecar: dict, pdf_path: str, doc) -> list:
    """核对笔迹文件里记的文档指纹，返回需要提醒的行。

    拿错书时，笔迹会整体错位到"看起来正常、其实不对"的位置上——这是这类导出最容易
    踩的坑，所以文件大小、页数、页码范围三者都验一遍。
    """
    notes = []
    meta = sidecar.get("doc") or {}
    size = os.path.getsize(pdf_path)
    pages = doc.page_count

    if meta.get("bytes"):
        try:
            recorded = int(meta["bytes"])
        except (TypeError, ValueError):
            recorded = 0
        if recorded and recorded != size:
            notes.append("注意：文档大小不一致——笔迹文件记录 %s，实际 %s。"
                         "若不是同一份文件，页码可能对不上。"
                         % (_human(recorded), _human(size)))
    if meta.get("pages"):
        try:
            recorded_pages = int(meta["pages"])
        except (TypeError, ValueError):
            recorded_pages = 0
        if recorded_pages and recorded_pages != pages:
            notes.append("注意：页数不一致——笔迹文件记录 %d 页，实际 %d 页。"
                         % (recorded_pages, pages))
    if meta.get("name"):
        notes.append("提示：笔迹文件记录的文档是 %s" % meta["name"])

    numbers = []
    for key in sidecar["pages"]:
        try:
            numbers.append(int(key))
        except (TypeError, ValueError):
            continue
    out_of_range = [p for p in numbers if p < 1 or p > pages]
    if out_of_range:
        notes.append("注意：有 %d 页笔迹超出 PDF 页数（%s），会被跳过。"
                     % (len(out_of_range),
                        ", ".join(str(p) for p in sorted(out_of_range)[:8])))
    return notes


# ---------------------------------------------------------------------------
# 导出
# ---------------------------------------------------------------------------
def find_sidecar(pdf_path: str, explicit: str | None) -> str:
    if explicit:
        if os.path.isdir(explicit):
            for name in (SIDECAR_NAME, SIDECAR_NAME.replace(".lua", ".json")):
                candidate = os.path.join(explicit, name)
                if os.path.isfile(candidate):
                    return candidate
            raise FileNotFoundError("%s 里没有 %s（也没有同名 .json）"
                                    % (explicit, SIDECAR_NAME))
        return explicit

    stem = os.path.splitext(os.path.basename(pdf_path))[0]
    folder = os.path.dirname(os.path.abspath(pdf_path))
    sdr = os.path.join(folder, stem + ".sdr")
    # 首选设备上的 .lua；其次是菜单导出的 .json（后者更好传，内容一样）
    for name in (SIDECAR_NAME, SIDECAR_NAME.replace(".lua", ".json")):
        candidate = os.path.join(sdr, name)
        if os.path.isfile(candidate):
            return candidate
    # 文件名不同（极少见）：在 .sdr 里找任何笔迹文件
    if os.path.isdir(sdr):
        found = sorted(f for f in os.listdir(sdr)
                       if "pencil" in f.lower() and f.endswith((".lua", ".json")))
        if found:
            return os.path.join(sdr, found[0])
    raise FileNotFoundError(
        "没有找到 %s。请用 --sidecar 指定路径（通常是 <书名>.sdr/%s，"
        "或插件菜单导出的 pencil_handwriting.json）" % (SIDECAR_NAME, SIDECAR_NAME))


def gray_rgb(color: str):
    level = COLORS.get(color, 0x00)
    return (level / 255.0,) * 3, level


def draw_strokes(page, strokes, derotate):
    """把一组笔画画到 PyMuPDF 页面上，返回画了几笔。

    PyMuPDF 的页面坐标与 KOReader 的页面坐标同为「左上原点、y 向下」，
    因此坐标可以直接使用；只有带 /Rotate 的页面需要额外换算。
    """
    drawn = 0
    for stroke in strokes:
        pts = stroke.points
        if len(pts) < 2:
            continue
        rgb, _ = gray_rgb(stroke.color)
        width = max(0.1, stroke.width)
        pairs = [(pymupdf.Point(pts[i], pts[i + 1])) for i in range(0, len(pts) - 1, 2)]
        if derotate is not None:
            pairs = [p * derotate for p in pairs]

        for i in range(len(pairs) - 1):
            page.draw_line(pairs[i], pairs[i + 1], color=rgb, width=width,
                           lineCap=1, lineJoin=1)
        if len(pairs) == 1:
            # 单点（极少见）：画一个极短的笔画，等价于一个圆点
            page.draw_line(pairs[0], pairs[0] + pymupdf.Point(0.01, 0.01),
                           color=rgb, width=width, lineCap=1)
        drawn += 1
    return drawn


def build_report(doc, sidecar, pdf_path):
    lines = []
    lines.append("PDF      : %s（%d 页）" % (pdf_path, doc.page_count))
    lines.append("存储格式 : v%s" % sidecar["version"])
    pages = sidecar["pages"]

    by_space = {}
    numeric_pages = []
    nonnumeric = []
    for key, strokes in pages.items():
        try:
            page_no = int(key)
        except (TypeError, ValueError):
            nonnumeric.append(str(key))
            continue
        numeric_pages.append(page_no)
        for s in strokes:
            by_space[s.space] = by_space.get(s.space, 0) + 1

    total = sum(len(v) for v in pages.values())
    lines.append("笔迹     : 共 %d 笔，分布在 %d 页" % (total, len(pages)))
    if by_space:
        lines.append("坐标系   : " + "，".join("%s=%d" % kv for kv in sorted(by_space.items())))

    if numeric_pages:
        lines.append("页码范围 : %d – %d" % (min(numeric_pages), max(numeric_pages)))
        out_of_range = [p for p in numeric_pages if p < 1 or p > doc.page_count]
        if out_of_range:
            lines.append("注意：超出 PDF 页数的页码（会被跳过）：%s" % sorted(out_of_range))
    if nonnumeric:
        lines.append("注意：非数字页键（重排文档，无法映射到 PDF）：%s" % nonnumeric[:5])

    exportable = sum(1 for strokes in pages.values()
                     for s in strokes if s.space == "page")
    skipped = total - exportable
    lines.append("可导出   : %d 笔（space=page）" % exportable)
    if skipped:
        lines.append("注意：跳过   : %d 笔（space=native，坐标锚在屏幕而非页面，无法定位到 PDF）" % skipped)

    white = sum(1 for strokes in pages.values() for s in strokes
                if s.space == "page" and s.color == "white")
    if white:
        lines.append("注意：%d 笔是白色，在白底 PDF 上看不见" % white)

    rotated = [i + 1 for i in range(doc.page_count) if doc[i].rotation]
    if rotated:
        lines.append("注意：带 /Rotate 的页面：%s（已按显示方向校正，建议目视核对这几页）"
                     % rotated[:8])
    return "\n".join(lines)


def export(args) -> int:
    pdf_path = args.pdf
    if not os.path.isfile(pdf_path):
        print("找不到 PDF：%s" % pdf_path)
        return 2

    sidecar_path = find_sidecar(pdf_path, args.sidecar)
    sidecar = load_sidecar(sidecar_path)

    stem = os.path.splitext(os.path.basename(pdf_path))[0]
    out_dir = args.out or os.path.join(os.path.dirname(os.path.abspath(pdf_path)),
                                       "pencil-export", stem)

    doc = pymupdf.open(pdf_path)
    print(build_report(doc, sidecar, pdf_path))
    for note in verify_document(sidecar, pdf_path, doc):
        print(note)
    print("sidecar  : %s" % sidecar_path)
    print("输出目录 : %s" % out_dir)
    if args.mode == "report":
        print("\n（--mode report：只报告，未写文件）")
        return 0

    os.makedirs(out_dir, exist_ok=True)
    pages = sidecar["pages"]

    def strokes_of(page_index):
        """该 PDF 页（0 基）上可导出的笔画。"""
        picked = []
        for key, strokes in pages.items():
            try:
                if int(key) - 1 == page_index:
                    picked.extend(s for s in strokes if s.space == "page")
            except (TypeError, ValueError):
                continue
        return picked

    written = []
    mode = args.mode

    if mode in ("flatten", "png", "all"):
        flat = pymupdf.open(pdf_path)
        total = 0
        for i in range(flat.page_count):
            page = flat[i]
            strokes = strokes_of(i)
            if not strokes:
                continue
            derotate = page.derotation_matrix if page.rotation else None
            total += draw_strokes(page, strokes, derotate)
        if mode != "png":
            target = os.path.join(out_dir, stem + "_annotated.pdf")
            flat.save(target, garbage=4, deflate=True)
            written.append((target, total))
        if mode in ("png", "all"):
            pages_dir = os.path.join(out_dir, "pages")
            os.makedirs(pages_dir, exist_ok=True)
            if mode == "all":
                flat.close()
                flat = pymupdf.open(os.path.join(out_dir, stem + "_annotated.pdf"))
            for i in range(flat.page_count):
                pix = flat[i].get_pixmap(dpi=args.dpi)
                name = "page-%04d.png" % (i + 1)
                pix.save(os.path.join(pages_dir, name))
            written.append((pages_dir, flat.page_count))
        flat.close()

    if mode in ("overlay", "all"):
        overlay = pymupdf.open()
        total = 0
        for i in range(doc.page_count):
            src = doc[i]
            page = overlay.new_page(width=src.rect.width, height=src.rect.height)
            strokes = strokes_of(i)
            total += draw_strokes(page, strokes, None)
        target = os.path.join(out_dir, stem + "_ink.pdf")
        overlay.save(target, garbage=4, deflate=True)
        overlay.close()
        written.append((target, total))

    print()
    for path, count in written:
        print("已写出：%s（%s）" % (path, "%d 笔" % count if path.endswith(".pdf") else "%d 页" % count))
    doc.close()

    if args.open and os.name == "nt":
        try:
            os.startfile(out_dir)  # noqa: S606 - 只是想打开文件夹
        except Exception as exc:  # pragma: no cover - 打不开也不该让导出失败
            print("（未能自动打开文件夹：%s）" % exc)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="把 pencil-handwriting.koplugin 的笔迹导出到 PDF / PNG",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pdf", required=True, help="原始 PDF 路径")
    parser.add_argument("--sidecar", default=None,
                        help="pencil_handwriting.lua 的路径或其所在目录（默认自动寻找 <书名>.sdr/）")
    parser.add_argument("--out", default=None,
                        help="输出目录（默认 <PDF 目录>/pencil-export/<书名>/）")
    parser.add_argument("--mode", default="flatten",
                        choices=["flatten", "overlay", "png", "all", "report"],
                        help="flatten=叠加笔迹的 PDF（默认）；overlay=只有笔迹的透明层；"
                             "png=每页图片；all=全部；report=只报告")
    parser.add_argument("--dpi", type=int, default=200, help="PNG 渲染精度（默认 200）")
    parser.add_argument("--open", action="store_true",
                        help="导出完成后打开输出文件夹（Windows）")
    return export(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
