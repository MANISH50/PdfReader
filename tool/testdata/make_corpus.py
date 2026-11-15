#!/usr/bin/env python3
"""PdfReader test-PDF corpus generator (dev tool only, never shipped).

Produces valid, encrypted, form, multi-script, rotated, annotated, malformed
and fuzzed PDFs plus a manifest.json that states what the app must do with
each file (open / ask for a password / fail gracefully with which category).

Usage (see TESTING.md):
    python3 -m venv /tmp/corpus-venv
    /tmp/corpus-venv/bin/pip install -r tool/testdata/requirements.txt
    /tmp/corpus-venv/bin/python tool/testdata/make_corpus.py --out test_assets/pdfs
    # optional extras (never commit these):
    /tmp/corpus-venv/bin/python tool/testdata/make_corpus.py --out build/corpus --huge

Fonts: Noto Sans Arabic / Hebrew / Devanagari (SIL Open Font License 1.1) are
fetched from the google/fonts GitHub repository at *generation time* and
cached in --font-cache. If the download fails, system fonts are used
(GNU FreeSerif, GPLv3 with font-embedding exception). Subsets are embedded in
the generated PDFs, which both licenses allow. The app never downloads fonts.

Everything is deterministic for a given --seed except the AES salts in the
encrypted files.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import random
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path

try:
    import pikepdf
    from pikepdf import Array, Dictionary, Name, String
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
    from reportlab.lib.pagesizes import A4, A5, LETTER, landscape
    from reportlab.lib.utils import ImageReader
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.pdfgen import canvas
except ImportError as e:  # pragma: no cover
    sys.exit(f"missing dependency ({e}); pip install -r tool/testdata/requirements.txt")

try:  # optional: OpenType shaping for Arabic joining / Devanagari conjuncts
    import uharfbuzz  # noqa: F401

    HAVE_SHAPING = True
except ImportError:  # pragma: no cover
    HAVE_SHAPING = False

MANIFEST_VERSION = 1
# Pinned google/fonts commit so the corpus is reproducible.
GOOGLE_FONTS_RAW = "https://raw.githubusercontent.com/google/fonts/cc39c4c2c304bc368c9b7c311ea2bcc6013299fe/ofl"
NOTO = {
    "arabic": ("notosansarabic", "NotoSansArabic"),
    "hebrew": ("notosanshebrew", "NotoSansHebrew"),
    "devanagari": ("notosansdevanagari", "NotoSansDevanagari"),
}
SYSTEM_FALLBACK = ["FreeSerif.ttf", "DejaVuSans.ttf"]
SMALL_LIMIT = 300 * 1024

WORDS = (
    "the quick brown fox jumps over lazy dog reading private offline document page "
    "chapter layout render glyph font stream object xref trailer catalog outline "
    "bookmark annotation highlight margin column paragraph sentence word letter ink "
    "paper library shelf author river mountain window lantern harbor meadow garden"
).split()
NEEDLE = "needle"
NEEDLE_PAGES = [3, 11, 18]


@dataclass
class Entry:
    path: str
    category: str  # valid | protected | malformed | fuzz | large
    expect: str  # opens | needs_password | fails | fails_or_opens
    description: str
    failure: str | None = None  # expected OpenFailure name when it fails
    password: str | None = None
    pages: int | None = None
    text: list[str] = field(default_factory=list)  # substrings expected in extracted text
    features: dict = field(default_factory=dict)
    commit: bool = True


class Corpus:
    def __init__(self, out: Path, seed: int, font_cache: Path):
        self.out = out
        self.seed = seed
        self.rng = random.Random(seed)
        self.font_cache = font_cache
        self.entries: list[Entry] = []
        self.fonts_used: dict[str, str] = {}
        out.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------ utils
    def write(self, rel: str, data: bytes, entry: Entry) -> None:
        p = self.out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        entry.path = rel
        self.entries.append(entry)
        print(f"  {rel:45s} {len(data):>12,d} B")

    @staticmethod
    def save_pike(pdf: "pikepdf.Pdf", **kw) -> bytes:
        buf = io.BytesIO()
        if "encryption" not in kw:
            kw.setdefault("deterministic_id", True)
        pdf.save(buf, **kw)
        return buf.getvalue()

    def new_canvas(self, pagesize=A4):
        buf = io.BytesIO()
        c = canvas.Canvas(buf, pagesize=pagesize, invariant=1, pageCompression=1)
        c.setAuthor("PdfReader QA corpus")
        c.setCreator("tool/testdata/make_corpus.py")
        return c, buf

    def para(self, n_words: int) -> str:
        return " ".join(self.rng.choice(WORDS) for _ in range(n_words))

    # ------------------------------------------------------------------ fonts
    def font(self, script: str) -> tuple[str, str]:
        """Returns (reportlab font name, license note) for a script."""
        name = f"QA-{script}"
        if name in pdfmetrics.getRegisteredFontNames():
            return name, self.fonts_used[name]
        path, lic = self._fetch_noto(script)
        if path is None:
            path, lic = self._system_font()
        pdfmetrics.registerFont(TTFont(name, str(path)))
        self.fonts_used[name] = lic
        return name, lic

    def _fetch_noto(self, script: str):
        folder, base = NOTO[script]
        self.font_cache.mkdir(parents=True, exist_ok=True)
        static = self.font_cache / f"{base}-Regular-static.ttf"
        if static.exists():
            return static, f"{base} (SIL OFL 1.1, google/fonts)"
        try:
            url = f"{GOOGLE_FONTS_RAW}/{folder}/{base}%5Bwdth,wght%5D.ttf"
            raw = self.font_cache / f"{base}-VF.ttf"
            with urllib.request.urlopen(url, timeout=60) as r:
                raw.write_bytes(r.read())
            with urllib.request.urlopen(f"{GOOGLE_FONTS_RAW}/{folder}/OFL.txt", timeout=60) as r:
                (self.font_cache / f"{base}-OFL.txt").write_bytes(r.read())
            from fontTools.ttLib import TTFont as FTFont
            from fontTools.varLib import instancer

            vf = FTFont(str(raw))
            axes = {a.axisTag: a.defaultValue for a in vf["fvar"].axes} if "fvar" in vf else {}
            axes.update({k: v for k, v in {"wght": 400, "wdth": 100}.items() if k in axes})
            inst = instancer.instantiateVariableFont(vf, axes) if axes else vf
            inst.save(str(static))
            return static, f"{base} (SIL OFL 1.1, google/fonts)"
        except Exception as e:  # network or fontTools failure: fall back
            print(f"  ! could not fetch {base}: {e}; using a system font")
            return None, None

    @staticmethod
    def _system_font():
        try:
            listing = subprocess.run(["fc-list", ":", "file"], capture_output=True, text=True).stdout
        except FileNotFoundError:
            listing = ""
        for want in SYSTEM_FALLBACK:
            for line in listing.splitlines():
                f = line.split(":")[0].strip()
                if f.endswith("/" + want):
                    return Path(f), f"{want} (system font; FreeFont GPLv3+font exception / DejaVu license)"
        sys.exit("no font with Arabic/Hebrew/Devanagari coverage found; install fonts-freefont-ttf")

    def draw_script(self, c, x, y, text: str, font: str, size: float, rtl: bool = False):
        c.setFont(font, size)
        if HAVE_SHAPING:
            # HarfBuzz output is already in visual order for a single-direction run.
            if rtl:
                c.drawRightString(x, y, text, shaping=True)
            else:
                c.drawString(x, y, text, shaping=True)
        else:  # no shaping available: logical order, isolated glyph forms
            if rtl:
                c.drawRightString(x, y, text[::-1])
            else:
                c.drawString(x, y, text)

    # ============================================================ valid files
    def tiny(self):
        c, buf = self.new_canvas(A4)
        c.setTitle("Tiny")
        c.setFont("Helvetica-Bold", 28)
        c.drawString(72, 760, "Hello PdfReader")
        c.setFont("Helvetica", 12)
        c.drawString(72, 730, "A one page document for smoke tests.")
        c.showPage()
        c.save()
        self.write("tiny.pdf", buf.getvalue(), Entry(
            "", "valid", "opens", "One A4 page with two lines of Helvetica text.",
            pages=1, text=["Hello PdfReader"]))

    def text_multi(self):
        c, buf = self.new_canvas(A4)
        c.setTitle("Multi-page text sample")
        w, h = A4
        pages = 20
        # Page 1: table of contents with internal links.
        c.bookmarkPage("p1")
        c.addOutlineEntry("Contents", "p1", level=0)
        c.setFont("Helvetica-Bold", 24)
        c.drawString(72, h - 90, "Contents")
        c.setFont("Helvetica", 12)
        for i in range(2, pages + 1):
            y = h - 120 - (i - 2) * 18
            label = f"Chapter {i - 1} ........ page {i}"
            c.drawString(90, y, label)
            c.linkAbsolute(label, f"p{i}", Rect=(88, y - 3, 360, y + 12), thickness=0)
        y = h - 120 - (pages - 1) * 18 - 20
        c.drawString(90, y, "Project site: https://example.com/pdfreader")
        c.linkURL("https://example.com/pdfreader", (88, y - 3, 360, y + 12), relative=0, thickness=0)
        self.js_link_rect = (88, y - 40 - 3, 360, y - 40 + 12)
        c.drawString(90, y - 40, "Do not click: javascript link (must be blocked)")
        self.launch_link_rect = (88, y - 60 - 3, 360, y - 60 + 12)
        c.drawString(90, y - 60, "Do not click: launch action (must be ignored)")
        c.showPage()
        for i in range(2, pages + 1):
            c.bookmarkPage(f"p{i}")
            c.addOutlineEntry(f"Chapter {i - 1}", f"p{i}", level=0)
            c.setFont("Helvetica-Bold", 20)
            c.drawString(72, h - 80, f"Chapter {i - 1}")
            yy = h - 115
            for s in range(1, 4):
                c.bookmarkHorizontal(f"p{i}s{s}", 0, yy + 20)
                c.addOutlineEntry(f"Section {i - 1}.{s}", f"p{i}s{s}", level=1)
                c.setFont("Helvetica-Bold", 14)
                c.drawString(72, yy, f"Section {i - 1}.{s}")
                yy -= 20
                c.setFont("Times-Roman", 11)
                for line in range(12):
                    txt = self.para(13)
                    if i in NEEDLE_PAGES and s == 2 and line == 4:
                        txt = f"here is the {NEEDLE} in the haystack " + txt[:40]
                    c.drawString(72, yy, txt)
                    yy -= 14
                yy -= 10
            if i < pages:
                c.setFont("Helvetica", 10)
                c.drawString(72, 50, "Next chapter")
                c.linkAbsolute("next", f"p{i + 1}", Rect=(70, 47, 140, 60), thickness=0)
            c.setFont("Helvetica", 9)
            c.drawCentredString(w / 2, 30, f"{i}")
            c.showPage()
        c.showOutline()
        c.save()

        pdf = pikepdf.open(io.BytesIO(buf.getvalue()))
        p1 = pdf.pages[0]
        annots = p1.obj.get("/Annots", Array())
        annots.append(pdf.make_indirect(Dictionary(
            Type=Name.Annot, Subtype=Name.Link, Rect=Array(list(self.js_link_rect)), Border=Array([0, 0, 0]),
            A=Dictionary(S=Name.URI, URI=String("javascript:alert('pwned')")))))
        annots.append(pdf.make_indirect(Dictionary(
            Type=Name.Annot, Subtype=Name.Link, Rect=Array(list(self.launch_link_rect)), Border=Array([0, 0, 0]),
            A=Dictionary(S=Name.Launch, F=String("/bin/sh"),
                         Win=Dictionary(F=String("cmd.exe"), P=String("/c calc.exe"))))))
        p1.obj.Annots = annots
        pdf.Root.OpenAction = Dictionary(S=Name.JavaScript, JS=String("app.alert('OpenAction JavaScript ran');"))
        pdf.Root.Names = pdf.Root.get("/Names", Dictionary())
        pdf.Root.Names.JavaScript = Dictionary(Names=Array([
            String("init"), Dictionary(S=Name.JavaScript, JS=String("this.print({bUI:false});"))]))
        pdf.attachments["attachment.txt"] = pikepdf.AttachedFileSpec(
            pdf, b"Embedded file content. The app must never open or execute this.\n",
            description="Embedded file attachment", mime_type="text/plain")
        data = self.save_pike(pdf)
        self.write("text_multi.pdf", data, Entry(
            "", "valid", "opens",
            "20 A4 pages: headings, paragraphs, outline (19 chapters x 3 sections), internal links "
            "(TOC on page 1 + 'next chapter'), external https link, javascript: URI link, Launch action, "
            "OpenAction + Names JavaScript, one embedded file attachment.",
            pages=pages, text=["Contents", "Chapter 1"],
            features={"search": {"term": NEEDLE, "pages": NEEDLE_PAGES},
                      "outlineTopLevel": pages, "externalLink": "https://example.com/pdfreader",
                      "blockedLinks": ["javascript:alert('pwned')", "Launch"],
                      "javascript": True, "attachments": ["attachment.txt"]}))

    def scanned(self):
        c, buf = self.new_canvas(A4)
        c.setTitle("Scanned (image only)")
        w, h = A4
        try:
            font = ImageFont.load_default(size=19)
        except TypeError:  # very old Pillow
            font = ImageFont.load_default()
        for pg in range(1, 4):
            img = Image.new("L", (661, 935), 245)  # 80 dpi A4
            d = ImageDraw.Draw(img)
            d.text((70, 60), f"Scanned page {pg}", fill=20, font=font)
            for line in range(32):
                d.text((60, 110 + line * 25), self.para(9), fill=40, font=font)
            noise = Image.frombytes("L", img.size, self.rng.randbytes(img.size[0] * img.size[1]))
            img = Image.blend(img, noise, 0.03).rotate(0.7, fillcolor=235).filter(ImageFilter.SMOOTH)
            jb = io.BytesIO()
            img.save(jb, "JPEG", quality=30, optimize=True)
            c.drawImage(ImageReader(io.BytesIO(jb.getvalue())), 0, 0, width=w, height=h)
            c.showPage()
        c.save()
        self.write("scanned.pdf", buf.getvalue(), Entry(
            "", "valid", "opens", "3 image-only pages (JPEG 'scan', no text layer). Text extraction is empty; "
            "search must report 'no text layer' instead of failing.", pages=3,
            features={"textLayer": False}))

    def protected(self):
        base = pikepdf.open(self.out / "tiny.pdf")
        data = self.save_pike(base, encryption=pikepdf.Encryption(user="test123", owner="owner-secret", R=6))
        self.write("password.pdf", data, Entry(
            "", "protected", "needs_password",
            "tiny.pdf encrypted with AES-256 (R=6), user password 'test123'. Wrong password must give "
            "wrongPassword; cancel must give cancelled.", failure="wrongPassword", password="test123",
            pages=1, text=["Hello PdfReader"], features={"encryption": "AES-256"}))
        base = pikepdf.open(self.out / "tiny.pdf")
        perms = pikepdf.Permissions(accessibility=False, extract=False, modify_annotation=False,
                                    modify_assembly=False, modify_form=False, modify_other=False,
                                    print_lowres=False, print_highres=False)
        data = self.save_pike(base, encryption=pikepdf.Encryption(user="", owner="owner-secret", R=6, allow=perms))
        self.write("owner-only-protected.pdf", data, Entry(
            "", "protected", "opens",
            "AES-256 with empty user password and an owner password; permissions deny print/copy/modify. "
            "Must open without a prompt; the app should show restrictions.", pages=1,
            text=["Hello PdfReader"], features={"encryption": "AES-256", "restricted": True}))

    def forms(self):
        c, buf = self.new_canvas(LETTER)
        c.setTitle("AcroForm sample")
        w, h = LETTER
        form = c.acroForm
        c.setFont("Helvetica-Bold", 18)
        c.drawString(72, h - 72, "Registration form")
        c.setFont("Helvetica", 12)
        c.drawString(72, h - 120, "Full name:")
        form.textfield(name="full_name", tooltip="Full name", x=180, y=h - 128, width=300, height=20,
                       value="", borderStyle="inset", forceBorder=True)
        c.drawString(72, h - 160, "Notes:")
        form.textfield(name="notes", tooltip="Notes", x=180, y=h - 220, width=300, height=70,
                       value="Line one", fieldFlags="multiline", forceBorder=True)
        c.drawString(72, h - 260, "Subscribe:")
        form.checkbox(name="subscribe", tooltip="Subscribe", x=180, y=h - 266, size=16,
                      buttonStyle="check", checked=False, forceBorder=True)
        c.drawString(72, h - 300, "Colour:")
        for i, (val, sel) in enumerate([("red", True), ("green", False), ("blue", False)]):
            form.radio(name="colour", tooltip=f"Colour {val}", value=val, selected=sel,
                       x=180 + i * 80, y=h - 306, size=16, buttonStyle="circle", forceBorder=True)
            c.drawString(200 + i * 80, h - 300, val)
        c.drawString(72, h - 340, "Country:")
        form.choice(name="country", tooltip="Country", value="India", x=180, y=h - 346, width=200,
                    height=20, options=["India", "Israel", "Egypt", "Germany", "Brazil"], forceBorder=True)
        c.drawString(72, h - 380, "Languages:")
        form.listbox(name="languages", tooltip="Languages", value="English", x=180, y=h - 460, width=200,
                     height=90, options=["English", "Hindi", "Arabic", "Hebrew", "German"], forceBorder=True)
        c.showPage()
        c.save()
        self.write("forms.pdf", buf.getvalue(), Entry(
            "", "valid", "opens", "AcroForm with text (single + multiline), checkbox, radio group (3), "
            "combo box and list box fields.", pages=1, text=["Registration form"],
            features={"fields": {"full_name": "text", "notes": "text", "subscribe": "checkbox",
                                 "colour": "radio", "country": "combo", "languages": "list"}}))

    def rtl(self):
        ar, lic_ar = self.font("arabic")
        he, lic_he = self.font("hebrew")
        c, buf = self.new_canvas(A4)
        c.setTitle("Arabic and Hebrew")
        w, h = A4
        arabic = ["مرحبا بالعالم", "هذا مستند اختبار لقارئ الملفات", "القراءة الخاصة بدون اتصال"]
        hebrew = ["שלום עולם", "זהו מסמך בדיקה לקורא", "קריאה פרטית ללא חיבור"]
        c.setFont("Helvetica-Bold", 16)
        c.drawString(72, h - 72, "RTL sample (Arabic / Hebrew)")
        y = h - 120
        for line in arabic:
            self.draw_script(c, w - 72, y, line, ar, 18, rtl=True)
            y -= 32
        y -= 20
        for line in hebrew:
            self.draw_script(c, w - 72, y, line, he, 18, rtl=True)
            y -= 32
        c.showPage()
        c.save()
        self.write("rtl_arabic_hebrew.pdf", buf.getvalue(), Entry(
            "", "valid", "opens", f"One page of right-aligned Arabic and Hebrew text. Fonts: {lic_ar}; {lic_he}. "
            f"Shaped with HarfBuzz: {HAVE_SHAPING}.", pages=1, text=["RTL sample"],
            features={"scripts": ["Arab", "Hebr"], "codepointRanges": [[0x0600, 0x06FF], [0x0590, 0x05FF]],
                      "shaped": HAVE_SHAPING}))

    def hindi(self):
        dv, lic = self.font("devanagari")
        c, buf = self.new_canvas(A4)
        c.setTitle("Hindi")
        w, h = A4
        lines = ["नमस्ते दुनिया", "यह पीडीएफ रीडर के लिए एक परीक्षण दस्तावेज़ है", "निजी और ऑफ़लाइन पढ़ना",
                 "क्षत्रिय श्रद्धा द्वार संयुक्त अक्षर"]
        c.setFont("Helvetica-Bold", 16)
        c.drawString(72, h - 72, "Hindi sample (Devanagari)")
        y = h - 120
        for line in lines:
            self.draw_script(c, 72, y, line, dv, 18)
            y -= 34
        c.showPage()
        c.save()
        self.write("hindi.pdf", buf.getvalue(), Entry(
            "", "valid", "opens", f"One page of Hindi incl. conjuncts. Font: {lic}. Shaped: {HAVE_SHAPING}.",
            pages=1, text=["Hindi sample"],
            features={"scripts": ["Deva"], "codepointRanges": [[0x0900, 0x097F]], "shaped": HAVE_SHAPING}))

    def mixed_rotation(self):
        specs = [  # (size, rotate, label)
            (A4, 0, "A4 portrait, /Rotate 0"),
            (A4, 90, "A4 portrait, /Rotate 90"),
            (LETTER, 180, "Letter, /Rotate 180"),
            (LETTER, 270, "Letter, /Rotate 270"),
            (landscape(A4), 0, "A4 landscape"),
            (A5, 0, "A5 portrait"),
            ((612, 14400), 0, "Very long page 612 x 14400 pt (PDF max side)"),
            ((14400, 300), 90, "Very wide banner 14400 x 300 pt, /Rotate 90"),
            ((200, 200), 0, "Small square 200 x 200 pt"),
        ]
        c, buf = self.new_canvas(A4)
        c.setTitle("Mixed rotation and sizes")
        for size, _, label in specs:
            c.setPageSize(size)
            w, h = size
            c.setStrokeGray(0.5)
            c.rect(10, 10, w - 20, h - 20)
            c.setFont("Helvetica-Bold", 14)
            c.drawString(20, h - 40, label)
            c.drawString(20, 20, "bottom-left (UP arrow points to page top)")
            c.line(w / 2, h / 2 - 40, w / 2, h / 2 + 40)
            c.line(w / 2, h / 2 + 40, w / 2 - 10, h / 2 + 28)
            c.line(w / 2, h / 2 + 40, w / 2 + 10, h / 2 + 28)
            c.showPage()
        c.save()
        pdf = pikepdf.open(io.BytesIO(buf.getvalue()))
        for page, (_, rot, _) in zip(pdf.pages, specs):
            if rot:
                page.obj.Rotate = rot
        self.write("mixed_rotation.pdf", self.save_pike(pdf), Entry(
            "", "valid", "opens", "9 pages: /Rotate 0/90/180/270, A4/Letter/A5/landscape, 612x14400 long page, "
            "14400x300 rotated banner, 200x200 square.", pages=len(specs), text=["A4 portrait"],
            features={"rotations": [r for _, r, _ in specs],
                      "sizesPt": [[float(s[0]), float(s[1])] for s, _, _ in specs]}))

    def annotated(self):
        c, buf = self.new_canvas(A4)
        c.setTitle("Annotated")
        w, h = A4
        c.setFont("Helvetica", 14)
        c.drawString(72, 700, "This sentence is highlighted by an existing annotation.")
        c.drawString(72, 600, "Ink scribble below:")
        c.showPage()
        c.save()
        pdf = pikepdf.open(io.BytesIO(buf.getvalue()))
        page = pdf.pages[0]

        def ap(content: bytes, bbox, gs=None):
            res = Dictionary()
            if gs:
                res.ExtGState = Dictionary(GS0=Dictionary(Type=Name.ExtGState, **gs))
            s = pikepdf.Stream(pdf, content)
            s.Type = Name.XObject
            s.Subtype = Name.Form
            s.BBox = Array(bbox)
            s.Resources = res
            return Dictionary(N=s)

        x1, y1, x2, y2 = 70, 695, 440, 714
        hl = Dictionary(
            Type=Name.Annot, Subtype=Name.Highlight, Rect=Array([x1, y1, x2, y2]),
            QuadPoints=Array([x1, y2, x2, y2, x1, y1, x2, y1]), C=Array([1, 0.92, 0.23]), CA=0.5,
            T=String("QA"), Contents=String("existing highlight"), F=4,
            AP=ap(b"/GS0 gs 1 0.92 0.23 rg %d %d %d %d re f" % (x1, y1, x2 - x1, y2 - y1),
                  [x1, y1, x2, y2], gs={"CA": 0.5, "ca": 0.5, "BM": Name.Multiply}))
        pts = [(100 + i * 12, 520 + (25 if i % 2 else -25)) for i in range(20)]
        flat = [v for p in pts for v in p]
        path = b"0 0 1 RG 3 w 1 J 1 j " + b"%d %d m " % pts[0] + b" ".join(b"%d %d l" % p for p in pts[1:]) + b" S"
        ink = Dictionary(
            Type=Name.Annot, Subtype=Name.Ink, Rect=Array([90, 485, 350, 555]), InkList=Array([Array(flat)]),
            C=Array([0, 0, 1]), BS=Dictionary(W=3), T=String("QA"), F=4, AP=ap(path, [90, 485, 350, 555]))
        note = Dictionary(Type=Name.Annot, Subtype=Name.Text, Rect=Array([460, 700, 480, 720]),
                          Contents=String("A sticky note"), Name=Name.Comment, C=Array([1, 1, 0]), F=4)
        page.obj.Annots = Array([pdf.make_indirect(hl), pdf.make_indirect(ink), pdf.make_indirect(note)])
        self.write("annotated.pdf", self.save_pike(pdf), Entry(
            "", "valid", "opens", "One page with an existing Highlight (with appearance stream), an Ink "
            "annotation and a Text (sticky note) annotation.", pages=1, text=["highlighted"],
            features={"annotations": ["Highlight", "Ink", "Text"]}))

    def huge(self):
        target_pages, target_bytes = 1200, 105 * 1024 * 1024
        pdf = pikepdf.new()
        total, i = 0, 0
        font = pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica))
        rng = random.Random(self.seed + 1)
        while i < target_pages or total < target_bytes:
            i += 1
            img = Image.frombytes("L", (340, 340), rng.randbytes(340 * 340))
            jb = io.BytesIO()
            img.save(jb, "JPEG", quality=92)
            jpg = jb.getvalue()
            total += len(jpg)
            xo = pikepdf.Stream(pdf, jpg)
            xo.Type, xo.Subtype = Name.XObject, Name.Image
            xo.Width, xo.Height, xo.ColorSpace, xo.BitsPerComponent = 340, 340, Name.DeviceGray, 8
            xo.Filter = Name.DCTDecode
            content = b"q 500 0 0 500 56 250 cm /Im0 Do Q BT /F1 24 Tf 56 780 Td (Huge page %d) Tj ET" % i
            page = pikepdf.Page(Dictionary(
                Type=Name.Page, MediaBox=Array([0, 0, 612, 842]),
                Resources=Dictionary(XObject=Dictionary(Im0=xo), Font=Dictionary(F1=font)),
                Contents=pikepdf.Stream(pdf, content)))
            pdf.pages.append(page)
        p = self.out / "huge.pdf"
        pdf.save(p, deterministic_id=True)
        size = p.stat().st_size
        self.entries.append(Entry("huge.pdf", "large", "opens",
                                  f"{i} pages, each an incompressible random-noise JPEG; {size / 1e6:.0f} MB. "
                                  "Generated on demand (--huge); never committed.",
                                  pages=i, text=["Huge page 1"], commit=False))
        print(f"  {'huge.pdf':45s} {size:>12,d} B")

    # ========================================================= malformed set
    @staticmethod
    def raw_pdf(objs: dict[int, bytes], root: int = 1, version: bytes = b"1.7", trailer_extra: bytes = b"",
                xref: bool = True) -> bytes:
        out = bytearray(b"%PDF-" + version + b"\n%\xe2\xe3\xcf\xd3\n")
        offsets = {}
        for num in sorted(objs):
            offsets[num] = len(out)
            out += b"%d 0 obj\n" % num + objs[num] + b"\nendobj\n"
        size = max(objs) + 1
        if xref:
            start = len(out)
            out += b"xref\n0 %d\n0000000000 65535 f \n" % size
            for n in range(1, size):
                out += (b"%010d 00000 n \n" % offsets[n]) if n in offsets else b"0000000000 65535 f \n"
            out += b"trailer\n<< /Size %d /Root %d 0 R %s>>\nstartxref\n%d\n%%%%EOF\n" % (size, root, trailer_extra,
                                                                                         start)
        return bytes(out)

    @staticmethod
    def stream(data: bytes, extra: bytes = b"", filt: bytes | None = None) -> bytes:
        f = b" /Filter " + filt if filt else b""
        return b"<< /Length %d%s %s>>\nstream\n" % (len(data), f, extra) + data + b"\nendstream"

    def basic_page(self, extra_page: bytes = b"", content: bytes = b"BT /F1 24 Tf 72 720 Td (Malformed) Tj ET",
                   mediabox: bytes = b"[0 0 612 792]", count: bytes = b"1", extra_objs=None, resources=None):
        res = resources or b"<< /Font << /F1 5 0 R >> >>"
        objs = {
            1: b"<< /Type /Catalog /Pages 2 0 R >>",
            2: b"<< /Type /Pages /Kids [3 0 R] /Count " + count + b" >>",
            3: b"<< /Type /Page /Parent 2 0 R /MediaBox " + mediabox + b" /Resources " + res +
               b" /Contents 4 0 R " + extra_page + b">>",
            4: self.stream(content),
            5: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        }
        objs.update(extra_objs or {})
        return self.raw_pdf(objs)

    def malformed(self):
        M = "malformed/"
        tiny = (self.out / "tiny.pdf").read_bytes()
        multi = (self.out / "text_multi.pdf").read_bytes()

        def add(name, data, desc, expect="fails_or_opens", failure="corrupted", **kw):
            self.write(M + name, data, Entry("", "malformed", expect, desc, failure=failure, **kw))

        add("zero_bytes.pdf", b"", "Empty file.", expect="fails", failure="notPdf")
        png = io.BytesIO()
        Image.new("RGB", (64, 64), (200, 30, 30)).save(png, "PNG")
        add("png_renamed.pdf", png.getvalue(), "A PNG image with a .pdf extension.", expect="fails", failure="notPdf")
        zb = io.BytesIO()
        with zipfile.ZipFile(zb, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("document.pdf", tiny)
            z.writestr("readme.txt", "zip renamed to pdf")
        add("zip_renamed.pdf", zb.getvalue(), "A ZIP archive (containing a PDF) with a .pdf extension.",
            expect="fails", failure="notPdf")
        add("text_renamed.pdf", b"Just some text, not a PDF at all.\n" * 20, "Plain text with a .pdf extension.",
            expect="fails", failure="notPdf")
        add("garbage_after_header.pdf", b"%PDF-1.7\n" + self.rng.randbytes(16 * 1024),
            "Valid header followed by 16 KiB of random bytes.", expect="fails", failure="corrupted")
        add("truncated.pdf", multi[: len(multi) * 6 // 10], "text_multi.pdf cut at 60% (no xref/trailer). "
            "PDFium may recover some pages.")
        add("truncated_header_only.pdf", tiny[:64], "First 64 bytes of tiny.pdf.", expect="fails")

        # Bad xref offsets: classic xref table with every offset shifted.
        pdf = pikepdf.open(io.BytesIO(tiny))
        classic = self.save_pike(pdf, object_stream_mode=pikepdf.ObjectStreamMode.disable, compress_streams=False)
        xpos = classic.rfind(b"\nxref\n") + 1
        head, tail = classic[:xpos], classic[xpos:]
        tail = re.sub(rb"(\d{10}) 00000 n", lambda m: b"%010d 00000 n" % (int(m.group(1)) * 7 + 13), tail)
        add("bad_xref_offsets.pdf", head + tail, "Classic xref table whose offsets all point to wrong places.")
        sx = classic.rfind(b"startxref")
        add("bad_startxref.pdf", classic[:sx] + b"startxref\n999999999\n%%EOF\n", "startxref points past EOF.")
        tr = classic.rfind(b"trailer")
        add("missing_trailer.pdf", classic[:tr], "Trailer, startxref and %%EOF removed.")
        add("missing_root.pdf", classic[:tr] + b"trailer\n<< /Size 9 >>\nstartxref\n%d\n%%%%EOF\n" % xpos,
            "Trailer without /Root.", expect="fails")

        # Circular structures.
        add("circular_pages_tree.pdf", self.raw_pdf({
            1: b"<< /Type /Catalog /Pages 2 0 R >>",
            2: b"<< /Type /Pages /Kids [2 0 R 3 0 R] /Count 2 >>",
            3: b"<< /Type /Pages /Parent 2 0 R /Kids [2 0 R 3 0 R] /Count 2 >>",
        }), "Pages tree whose /Kids reference the Pages node itself and each other.")
        add("circular_objects.pdf", self.basic_page(
            extra_page=b"/Annots 6 0 R /Parent 7 0 R",
            extra_objs={6: b"[6 0 R 8 0 R]", 7: b"<< /Type /Pages /Kids [3 0 R] /Count 1 /Parent 7 0 R >>",
                        8: b"<< /Type /Annot /Subtype /Link /Rect [0 0 1 1] /P 3 0 R /Next 8 0 R "
                           b"/A << /S /GoTo /D 8 0 R /Next 8 0 R >> >>",
                        9: b"<< /First 9 0 R /Last 9 0 R /Next 9 0 R /Prev 9 0 R /Parent 9 0 R /Count 5 >>"}),
            "Self-referencing Annots array, Parent loop, action /Next chain loop and an outline loop.")
        add("circular_outline.pdf", self.raw_pdf({
            1: b"<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>",
            2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            6: b"<< /Type /Outlines /First 7 0 R /Last 8 0 R /Count 2 >>",
            7: b"<< /Title (A) /Parent 6 0 R /Next 8 0 R /First 7 0 R /Dest [3 0 R /Fit] >>",
            8: b"<< /Title (B) /Parent 6 0 R /Prev 7 0 R /Next 7 0 R /Dest [3 0 R /Fit] >>",
        }), "Outline whose items loop (/Next back to the first, /First to itself).", expect="fails_or_opens")
        depth = 100_000
        add("deep_nesting.pdf", self.basic_page(extra_page=b"/Deep " + b"[" * depth + b"]" * depth + b" ",
                                                extra_objs={6: b"<< /A " + b"<< /A " * 2000 + b">>" * 2000 + b" >>"}),
            f"Page dictionary with an array nested {depth:,} levels deep plus a 2000-level dict.")
        add("deep_nesting_content.pdf", self.basic_page(content=b"q " * 40_000 + b"BT /F1 12 Tf (x) Tj ET"
                                                         + b" Q" * 40_000 + b" [" * 40_000),
            "Content stream with 40,000 nested q/Q and 40,000 unclosed arrays.")
        add("huge_page_count.pdf", self.basic_page(count=b"1000000000"),
            "/Count 1000000000 claimed, one real page. Must not allocate per claimed page.")
        add("negative_page_count.pdf", self.basic_page(count=b"-5"), "/Count -5.")
        add("huge_mediabox.pdf", self.basic_page(mediabox=b"[0 0 1000000000 1000000000]"),
            "MediaBox [0 0 1e9 1e9]. Rendering must clamp the bitmap size (SecurityLimits.maxRenderPixels).")
        add("inverted_mediabox.pdf", self.basic_page(mediabox=b"[612 792 0 0]"), "MediaBox with swapped corners.")
        add("zero_mediabox.pdf", self.basic_page(mediabox=b"[0 0 0 0]"), "Zero-area MediaBox.")
        add("nan_mediabox.pdf", self.basic_page(mediabox=b"[0 0 1e400 -1e400]"), "Overflowing MediaBox numbers.")

        # Decompression bombs (double Flate keeps the file tiny).
        bomb_size = 1024 * 1024 * 1024
        add("decompression_bomb.pdf", self.basic_page(content=b"", extra_page=b"",
                                                      extra_objs={4: self._bomb(bomb_size)}),
            "Page content stream: [/FlateDecode /FlateDecode] inflating to 1 GiB of whitespace.",
            features={"inflatedBytes": bomb_size})
        side = 20000
        img_bomb = self._bomb(side * side * 3, extra=b"/Type /XObject /Subtype /Image /Width %d /Height %d "
                                                    b"/ColorSpace /DeviceRGB /BitsPerComponent 8 " % (side, side))
        add("image_bomb.pdf", self.basic_page(content=b"q 612 0 0 792 0 0 cm /Im0 Do Q",
                                              resources=b"<< /XObject << /Im0 6 0 R >> >>",
                                              extra_objs={6: img_bomb}),
            f"Image XObject {side}x{side} RGB (1.2 GB decoded) from a tiny double-Flate stream.",
            features={"inflatedBytes": side * side * 3})
        add("bad_flate.pdf", self.basic_page(extra_objs={4: self.stream(self.rng.randbytes(4096),
                                                                         filt=b"/FlateDecode")}),
            "Content stream marked FlateDecode containing random bytes.")
        add("wrong_length.pdf", self.basic_page(extra_objs={4: b"<< /Length 999999 >>\nstream\nBT ET\nendstream"}),
            "Stream /Length far larger than the data.")

        # Invalid fonts.
        bad_ttf = self.stream(b"\x00\x01\x00\x00" + self.rng.randbytes(3000), extra=b"/Length1 3004 ")
        add("invalid_fonts.pdf", self.basic_page(
            content=b"BT /F1 24 Tf 72 720 Td (TrueType) Tj /F2 24 Tf 72 680 Td <0001000200030004> Tj "
                    b"/F3 24 Tf 72 640 Td (Type3) Tj ET",
            resources=b"<< /Font << /F1 6 0 R /F2 8 0 R /F3 11 0 R >> >>",
            extra_objs={
                6: b"<< /Type /Font /Subtype /TrueType /BaseFont /Broken /FirstChar 0 /LastChar 255 "
                   b"/Widths [-1 1e30] /FontDescriptor 7 0 R >>",
                7: b"<< /Type /FontDescriptor /FontName /Broken /Flags 32 /FontBBox [0 0 0 0] /ItalicAngle 0 "
                   b"/Ascent 9e9 /Descent -9e9 /CapHeight 0 /StemV 0 /FontFile2 10 0 R >>",
                8: b"<< /Type /Font /Subtype /Type0 /BaseFont /BrokenCID /Encoding /Identity-H "
                   b"/DescendantFonts [9 0 R] /ToUnicode 10 0 R >>",
                9: b"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /BrokenCID /CIDSystemInfo << /Registry (x) "
                   b"/Ordering (y) /Supplement 0 >> /FontDescriptor 7 0 R /W [0 [1e9 -1e9] 70000 65535 5] "
                   b"/CIDToGIDMap 10 0 R >>",
                10: bad_ttf,
                11: b"<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [0 0 0 0 0 0] "
                    b"/CharProcs << /a 12 0 R >> /Encoding << /Differences [0 /a] >> /FirstChar 0 /LastChar 0 "
                    b"/Widths [1] /Resources << /Font << /F3 11 0 R >> >> >>",
                12: self.stream(b"BT /F3 1 Tf (a) Tj ET"),
            }),
            "TrueType with garbage FontFile2, Type0 with bogus /W and CIDToGIDMap, recursive Type3 font.")

        # Broken images.
        def img_pdf(filt, data, extra=b""):
            xo = self.stream(data, extra=b"/Type /XObject /Subtype /Image /Width 640 /Height 480 "
                                         b"/ColorSpace /DeviceRGB /BitsPerComponent 8 " + extra, filt=filt)
            return self.basic_page(content=b"q 400 0 0 300 72 400 cm /Im0 Do Q",
                                   resources=b"<< /XObject << /Im0 6 0 R >> >>", extra_objs={6: xo})

        add("broken_jpeg.pdf", img_pdf(b"/DCTDecode", b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + self.rng.randbytes(5000)),
            "DCTDecode image: JPEG SOI/APP0 header then garbage.")
        add("broken_jpx.pdf", img_pdf(b"/JPXDecode", b"\x00\x00\x00\x0cjP  \r\n\x87\n" + self.rng.randbytes(5000)),
            "JPXDecode image: JP2 signature box then garbage.")
        add("broken_jbig2.pdf", self.basic_page(
            content=b"q 400 0 0 300 72 400 cm /Im0 Do Q",
            resources=b"<< /XObject << /Im0 6 0 R >> >>",
            extra_objs={6: self.stream(self.rng.randbytes(5000), filt=b"/JBIG2Decode",
                                       extra=b"/Type /XObject /Subtype /Image /Width 640 /Height 480 "
                                             b"/ColorSpace /DeviceGray /BitsPerComponent 1 "
                                             b"/DecodeParms << /JBIG2Globals 7 0 R >> "),
                        7: self.stream(b"\x97JB2\r\n\x1a\n" + self.rng.randbytes(2000))}),
            "JBIG2Decode image with garbage data and garbage JBIG2Globals.")
        add("broken_ccitt.pdf", img_pdf(b"/CCITTFaxDecode", self.rng.randbytes(5000),
                                        extra=b"/DecodeParms << /K -1 /Columns 640 /Rows 480 >> "),
            "CCITTFaxDecode image with garbage.")
        add("image_size_mismatch.pdf", img_pdf(None, b"\x80" * 100), "Raw 640x480 RGB image with only 100 bytes.")

        # Misc hostile structures.
        add("xref_stream_loop.pdf", tiny.replace(b"startxref", b"startxref\n0\n%%EOF\nstartxref", 1)
            if b"startxref" in tiny else tiny, "Extra startxref section pointing to offset 0.")
        add("many_incremental_updates.pdf", self._incremental(tiny, 300),
            "tiny.pdf plus 300 incremental-update sections whose /Prev chain loops.")
        add("pdf_version_garbage.pdf", b"%PDF-9.9" + tiny[8:], "Header claims PDF version 9.9.")
        add("null_bytes_in_names.pdf", self.basic_page(extra_page=b"/Foo#00Bar /Baz#ZZ /#20 "),
            "Names with #00, invalid #ZZ hex escapes.")

    @staticmethod
    def _bomb(size: int, extra: bytes = b"") -> bytes:
        inner = zlib.compressobj(9)
        chunk = b" " * (16 * 1024 * 1024) if not extra else b"\x00" * (16 * 1024 * 1024)
        parts = []
        left = size
        while left > 0:
            n = min(left, len(chunk))
            parts.append(inner.compress(chunk[:n]))
            left -= n
        parts.append(inner.flush())
        once = b"".join(parts)
        twice = zlib.compress(once, 9)
        return (b"<< /Length %d /Filter [/FlateDecode /FlateDecode] %s>>\nstream\n" % (len(twice), extra)
                + twice + b"\nendstream")

    @staticmethod
    def _incremental(base: bytes, n: int) -> bytes:
        out = bytearray(base)
        sx = base.rfind(b"startxref")
        prev = int(base[sx + 9:].split()[0])
        first = prev
        for i in range(n):
            start = len(out)
            out += b"\nxref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 1 /Prev %d >>\nstartxref\n%d\n%%%%EOF\n" % (
                prev if i else first, start)
            prev = start + 1
        # make the newest section's /Prev point at itself (loop)
        last = bytes(out).rfind(b"/Prev ")
        end = bytes(out).find(b" >>", last)
        out[last:end] = b"/Prev %d" % prev
        return bytes(out)

    # ================================================================== fuzz
    def fuzz(self, n: int):
        seeds = [e.path for e in self.entries
                 if e.category in ("valid", "malformed") and (self.out / e.path).stat().st_size <= 12 * 1024
                 and (self.out / e.path).stat().st_size > 100]
        frng = random.Random(self.seed * 7919 + n)
        interesting = [b"0", b"-1", b"4294967296", b"1e308", b"99999999999", b"[", b"<<", b"(", b"\x00", b"R",
                       b"obj", b"endstream", b"/Length 0", b"%%EOF"]
        for i in range(n):
            src = seeds[i % len(seeds)]
            data = bytearray((self.out / src).read_bytes())
            ops = []
            for _ in range(frng.randint(1, 8)):
                op = frng.choice(["flip", "byte", "delete", "dup", "insert", "number", "token", "truncate"])
                if not data:
                    break
                pos = frng.randrange(len(data))
                if op == "flip":
                    data[pos] ^= 1 << frng.randrange(8)
                elif op == "byte":
                    data[pos] = frng.randrange(256)
                elif op == "delete":
                    del data[pos:pos + frng.randint(1, 256)]
                elif op == "dup":
                    ln = frng.randint(1, 512)
                    data[pos:pos] = data[pos:pos + ln]
                elif op == "insert":
                    data[pos:pos] = frng.randbytes(frng.randint(1, 64))
                elif op == "number":
                    nums = [m.span() for m in re.finditer(rb"\d+", data)]
                    if nums:
                        a, b = frng.choice(nums)
                        data[a:b] = frng.choice(interesting[:5])
                elif op == "token":
                    data[pos:pos] = frng.choice(interesting)
                elif op == "truncate" and frng.random() < 0.3:
                    del data[pos:]
                ops.append(op)
            self.write(f"fuzz/fuzz_{i:03d}.pdf", bytes(data), Entry(
                "", "fuzz", "fails_or_opens", f"Seeded mutation of {src}: {', '.join(ops)}.",
                failure="corrupted", features={"seed": src}))

    # ============================================================== manifest
    def write_manifest(self):
        files = []
        for e in self.entries:
            p = self.out / e.path
            d = {"path": e.path, "category": e.category, "expect": e.expect, "description": e.description}
            for k in ("failure", "password", "pages"):
                if getattr(e, k) is not None:
                    d[k] = getattr(e, k)
            if e.text:
                d["text"] = e.text
            if e.features:
                d["features"] = e.features
            d["bytes"] = p.stat().st_size
            if e.commit and e.category != "large":
                d["sha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
            d["commit"] = e.commit and p.stat().st_size <= SMALL_LIMIT
            files.append(d)
        manifest = {
            "version": MANIFEST_VERSION,
            "generator": "tool/testdata/make_corpus.py",
            "seed": self.seed,
            "fonts": sorted(set(self.fonts_used.values())),
            "expectLegend": {
                "opens": "Must open, report the page count, render page 1 and load text.",
                "needs_password": "Must ask for a password; opens with 'password'; wrong password -> failure.",
                "fails": "Must fail gracefully with DocumentOpenException(failure) - never hang or crash.",
                "fails_or_opens": "Either opens (possibly with recovered pages) or fails with "
                                  "DocumentOpenException - never hangs or crashes.",
            },
            "files": files,
        }
        (self.out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                                                encoding="utf-8")
        big = [f["path"] for f in files if not f["commit"] and f["category"] != "large"]
        if big:
            print(f"  ! larger than {SMALL_LIMIT // 1024} KB (do not commit): {big}")


FIXTURE_FILES = ["tiny.pdf", "text_multi.pdf", "password.pdf", "forms.pdf"]


def write_dart_fixtures(corpus_dir: Path, target: Path) -> None:
    """Embeds a few small PDFs as base64 in a Dart file for integration tests.

    Integration tests run inside the app sandbox on a device and cannot read
    host files; embedding keeps the fixtures out of the release app's assets.
    """
    lines = [
        "// GENERATED by tool/testdata/make_corpus.py --dart-fixtures. Do not edit.",
        "// Test-only: imported by integration_test/ only, never by lib/.",
        "import 'dart:convert';",
        "import 'dart:typed_data';",
        "",
        "/// Small corpus PDFs, keyed by manifest path.",
        "final Map<String, Uint8List> corpusFixtures = {",
    ]
    for name in FIXTURE_FILES:
        b64 = base64.b64encode((corpus_dir / name).read_bytes()).decode()
        chunks = [b64[i:i + 100] for i in range(0, len(b64), 100)]
        lines.append(f"  '{name}': base64Decode(")
        lines += [f"    '{c}'" for c in chunks[:-1]]
        lines.append(f"    '{chunks[-1]}',")
        lines.append("  ),")
    lines += ["};", ""]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines), encoding="utf-8")
    print(f"  wrote Dart fixtures {target}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("build/corpus"), help="output dir (default build/corpus)")
    ap.add_argument("--seed", type=int, default=20261115)
    ap.add_argument("--fuzz", type=int, default=200, metavar="N", help="number of fuzz files (default 200, 0=off)")
    ap.add_argument("--huge", action="store_true", help="also write huge.pdf (1200+ pages, 100+ MB)")
    ap.add_argument("--no-malformed", action="store_true")
    ap.add_argument("--font-cache", type=Path, default=None, help="default: build/.corpus_fonts")
    ap.add_argument("--clean", action="store_true", help="delete the output dir first")
    ap.add_argument("--dart-fixtures", type=Path, default=None, metavar="FILE",
                    help="also embed small PDFs as base64 Dart (integration_test/fixtures/corpus_fixtures.g.dart)")
    a = ap.parse_args(argv)
    if a.clean and a.out.exists():
        shutil.rmtree(a.out)
    cache = a.font_cache or Path("build/.corpus_fonts")
    c = Corpus(a.out, a.seed, cache)
    print(f"Writing corpus to {a.out} (seed {a.seed}, shaping={HAVE_SHAPING})")
    c.tiny()
    c.text_multi()
    c.scanned()
    c.protected()
    c.forms()
    c.rtl()
    c.hindi()
    c.mixed_rotation()
    c.annotated()
    if not a.no_malformed:
        c.malformed()
    if a.fuzz:
        c.fuzz(a.fuzz)
    if a.huge:
        c.huge()
    c.write_manifest()
    if a.dart_fixtures:
        write_dart_fixtures(a.out, a.dart_fixtures)
    total = sum((a.out / e.path).stat().st_size for e in c.entries if e.commit)
    print(f"Done: {len(c.entries)} files, {total / 1e6:.2f} MB (excluding huge.pdf)")


if __name__ == "__main__":
    main()
