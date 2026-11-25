#!/usr/bin/env python3
"""scripts/make_annexure.py : the report's annexure, a PDF listing of every module and testbench.

  python3 scripts/make_annexure.py annexure.pdf            [--html annexure.html]

Annexure A is the design code (rtl/, the atan table generator, the multiplier design used for the
comparison), Annexure B the testbenches. The listings come straight from the files, with line
numbers and syntax colouring (pygments), printed by Chromium (playwright). Run it from anywhere;
paths are relative to the repository.
"""
import argparse
import datetime
import glob
import html
import os
import subprocess

from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import PythonLexer, SystemVerilogLexer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RTL_ORDER = ["cordic_ss", "control", "datapath", "shifter", "add_sub", "mux", "sync_reg", "atan_rom",
             "one_shifted", "error_correction", "cordic_pipe", "pipe_cut", "csa_tree"]
# unit tests first, then the engines and the system, in the order of the verification plan
TB_ORDER = ["tb_shifter", "tb_addsub", "tb_output", "tb_atan_rom", "tb_mux", "tb_one_shifted", "tb_sync_reg",
            "tb_csa_tree", "tb_pipe_cut", "tb_datapath", "tb_control", "tb_rotation", "tb_vectoring", "tb_linear",
            "tb_overflow", "tb_datatypes", "tb_pipeline", "tb_pipe_exhaustive", "tb_model_vectors", "tb_foc",
            "tb_guard_bits", "tb_examples", "tb_waves", "tb_cordic", "temp_tb"]


def testbenches():
    files = [f"tb/{t}.sv" for t in TB_ORDER]
    files += sorted(f for f in glob.glob("tb/*.sv", root_dir=REPO) if f not in files)   # any new ones too
    return files + ["tb/tb_common.svh", "tb/oop/cordic_if.sv", "tb/oop/cordic_pkg.sv", "tb/oop/tb_oop.sv",
                    "syn/tb_power.sv", "compare/tb_mult_rot.sv"]


GROUPS = [
    ("Annexure A: design code", [f"rtl/{m}.sv" for m in RTL_ORDER] + [
        "scripts/gen_atan_rom.py", "compare/mult_rot.sv", "compare/gen_sin_table.py", "compare/sin_table.sv"]),
    ("Annexure B: testbenches", testbenches()),
]

CSS = """
@page { size: Letter; margin: 0.55in 0.5in 0.6in 0.5in; }
body { font-family: 'IBM Plex Sans', 'DejaVu Sans', Arial, sans-serif; color: #1c2430; margin: 0; }
h1 { font-size: 20pt; margin: 0 0 6pt 0; }
h1.group { page-break-before: always; }
h1.group.first { page-break-before: auto; }
p.note { font-size: 9pt; color: #4a5560; margin: 0 0 10pt 0; }
table.files { border-collapse: collapse; font-size: 8.5pt; margin-bottom: 8pt; }
table.files td, table.files th { border-bottom: 1px solid #e1e0d9; padding: 2pt 8pt 2pt 0; text-align: left; }
.file { margin-top: 12pt; }
.fh { font-family: 'IBM Plex Mono', 'DejaVu Sans Mono', monospace; font-size: 9pt; font-weight: 600;
      background: #eef2f7; border-left: 3px solid #2a78d6; padding: 3pt 6pt; break-after: avoid; }
.fh span { font-weight: 400; color: #4a5560; }
.highlight pre { font-family: 'IBM Plex Mono', 'DejaVu Sans Mono', monospace; font-size: 7.2pt; line-height: 1.32;
                 white-space: pre-wrap; word-break: break-all; margin: 2pt 0 0 0; }
.highlight .linenos, .highlight span.linenos { color: #9aa0a6; padding-right: 6pt; }
"""


def listing(path):
    src = open(os.path.join(REPO, path), encoding="utf-8").read().expandtabs(4)
    lexer = PythonLexer() if path.endswith(".py") else SystemVerilogLexer()
    body = highlight(src, lexer, HtmlFormatter(linenos="inline", style="default", wrapcode=True))
    n = src.count("\n") + (0 if src.endswith("\n") else 1)
    return n, body


def build_html():
    parts, rows_all = [], []
    for g, (title, files) in enumerate(GROUPS):
        rows, blocks = [], []
        for f in files:
            n, body = listing(f)
            rows.append(f"<tr><td>{html.escape(f)}</td><td>{n}</td></tr>")
            blocks.append(f'<div class="file"><div class="fh">{html.escape(f)} <span>({n} lines)</span></div>{body}</div>')
            rows_all.append((title, f, n))
        total = sum(r[2] for r in rows_all if r[0] == title)
        parts.append(f'<h1 class="group{" first" if g == 0 else ""}">{html.escape(title)}</h1>'
                     f'<p class="note">{len(files)} files, {total:,} lines, printed from the repository on '
                     f'{datetime.date.today():%b %d, %Y}.</p>'
                     f'<table class="files"><tr><th>File</th><th>Lines</th></tr>{"".join(rows)}</table>'
                     + "".join(blocks))
    style = HtmlFormatter(style="default").get_style_defs(".highlight")
    return (f'<!doctype html><html><head><meta charset="utf-8"><style>{style}{CSS}</style></head><body>'
            + "".join(parts) + "</body></html>"), rows_all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--html")
    a = ap.parse_args()
    page, rows = build_html()
    html_path = a.html or os.path.splitext(a.pdf)[0] + ".html"
    open(html_path, "w", encoding="utf-8").write(page)
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto("file://" + os.path.abspath(html_path))
        pg.pdf(path=a.pdf, format="Letter", print_background=True, display_header_footer=True,
               header_template="<span></span>",
               footer_template='<div style="font-size:7pt;color:#898781;width:100%;text-align:center;'
                               'font-family:sans-serif">Annexure, page <span class="pageNumber"></span> of '
                               '<span class="totalPages"></span></div>',
               margin={"top": "0.55in", "bottom": "0.6in", "left": "0.5in", "right": "0.5in"})
        b.close()
    for title, f, n in rows:
        print(f"{title[:10]}  {f:32s} {n:5d}")
    print("wrote", a.pdf)


if __name__ == "__main__":
    main()
