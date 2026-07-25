#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="$REPO_ROOT/docs"
mkdir -p "$IMG_DIR"

KICAD_CLI="$(command -v kicad-cli || true)"
if [[ -z "$KICAD_CLI" ]]; then
    for cand in \
        "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli" \
        "/usr/bin/kicad-cli" \
        "/usr/local/bin/kicad-cli"; do
        [[ -x "$cand" ]] && KICAD_CLI="$cand" && break
    done
fi
[[ -z "$KICAD_CLI" ]] && { echo "error: kicad-cli not found" >&2; exit 1; }

svg2png() {
    local svg="$1" png="$2" width="${3:-1800}" bg="${4:-white}"
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$width" -b "$bg" "$svg" -o "$png"
    elif command -v inkscape >/dev/null 2>&1; then
        inkscape "$svg" --export-type=png --export-width="$width" \
            --export-background="$bg" --export-filename="$png" >/dev/null 2>&1
    elif command -v magick >/dev/null 2>&1; then
        magick -density 200 -background "$bg" -flatten "$svg" "$png"
    else
        convert -density 200 -background "$bg" -flatten "$svg" "$png"
    fi
}

BOARDS=(
    "amp|speek-amp|speek_amp"
    "rx|speek-rx|speek_rx"
    "psu|speek-psu|speek_psu"
)

for entry in "${BOARDS[@]}"; do
    IFS='|' read -r slug dir base <<<"$entry"
    pcb_root="$REPO_ROOT/$dir/PCB/$base"
    sch="$pcb_root/$base.kicad_sch"
    pcb="$pcb_root/$base.kicad_pcb"
    [[ -f "$pcb" ]] || { echo "warning: no PCB for $slug, skipping" >&2; continue; }

    echo ">> $slug: schematic"
    "$KICAD_CLI" sch export svg --output "$IMG_DIR/_tmp_$slug" --exclude-drawing-sheet "$sch" >/dev/null
    tmp_svg="$(find "$IMG_DIR/_tmp_$slug" -name '*.svg' | head -n1)"
    [[ -n "$tmp_svg" ]] && svg2png "$tmp_svg" "$IMG_DIR/${slug}_schematic.png"
    rm -rf "$IMG_DIR/_tmp_$slug"

    echo ">> $slug: F.Cu"
    "$KICAD_CLI" pcb export svg --output "$IMG_DIR/${slug}_fcu.svg" --mode-single \
        --layers F.Cu,F.Silkscreen,F.Mask,Edge.Cuts \
        --page-size-mode 2 --exclude-drawing-sheet "$pcb" >/dev/null
    svg2png "$IMG_DIR/${slug}_fcu.svg" "$IMG_DIR/${slug}_fcu.png" 1800 "#001124"
    rm -f "$IMG_DIR/${slug}_fcu.svg"

    echo ">> $slug: B.Cu"
    "$KICAD_CLI" pcb export svg --output "$IMG_DIR/${slug}_bcu.svg" --mode-single \
        --layers B.Cu,B.Silkscreen,B.Mask,Edge.Cuts --mirror \
        --page-size-mode 2 --exclude-drawing-sheet "$pcb" >/dev/null
    svg2png "$IMG_DIR/${slug}_bcu.svg" "$IMG_DIR/${slug}_bcu.png" 1800 "#001124"
    rm -f "$IMG_DIR/${slug}_bcu.svg"

    echo ">> $slug: 3D raytrace"
    "$KICAD_CLI" pcb render --output "$IMG_DIR/${slug}_3d.png" \
        --quality high --perspective --floor \
        --width 1600 --height 1200 \
        --rotate '-30,0,0' --background opaque "$pcb" >/dev/null

    echo ">> $slug: top-down banner tile"
    "$KICAD_CLI" pcb render --output "$IMG_DIR/_banner_${slug}.png" \
        --quality high --side top \
        --width 1600 --height 1600 \
        --background transparent "$pcb" >/dev/null

    echo ">> $slug: STEP"
    cad_dir="$REPO_ROOT/$dir/CAD"
    mkdir -p "$cad_dir"
    "$KICAD_CLI" pcb export step --output "$cad_dir/${base}.step" \
        --force --subst-models --no-optimize-step "$pcb" >/dev/null
done

echo ">> assembly STEP (stitched)"
step_files=()
for entry in "${BOARDS[@]}"; do
    IFS='|' read -r slug dir base <<<"$entry"
    step_files+=("$REPO_ROOT/$dir/CAD/${base}.step")
done
# Only build the assembly if every per-board STEP exists
have_all=1
for p in "${step_files[@]}"; do [[ -f "$p" ]] || { have_all=0; break; }; done
if [[ "$have_all" -eq 1 ]] && command -v uv >/dev/null 2>&1; then
    # Hybrid assembly: cadquery/OCCT computes each board's true extent
    # (transforms applied) for tight side-by-side layout, then a pure-text
    # merge produces the STEP. The text merge classifies each CARTESIAN_POINT
    # as board-space (translate it) vs component-local (leave it; the
    # component's placement transform carries it rigidly) by BFS from each
    # component's source representation. This avoids the OCCT re-encode that
    # balloons file size while keeping components attached to their boards.
    uv run --no-project --with cadquery python - "$REPO_ROOT" "${step_files[@]}" <<'PY'
import os, re, sys
import cadquery as cq

repo, steps = sys.argv[1], sys.argv[2:]
gap_mm = 5.0  # spacing between boards along X

CPT_RE = re.compile(
    r"(#\d+\s*=\s*CARTESIAN_POINT\s*\(\s*'(?:[^']|'')*'\s*,\s*\(\s*)"
    r"([^)]+?)(\s*\)\s*\)\s*;)"
)
# REPRESENTATION_RELATIONSHIP('','',#source_rep,#target_rep) inside a complex
# entity. source_rep = component (local coords); target_rep = board.
RR_RE = re.compile(
    r"REPRESENTATION_RELATIONSHIP\s*\(\s*'[^']*'\s*,\s*'[^']*'\s*,\s*#(\d+)\s*,\s*#(\d+)\s*\)"
)

def fmt_real(x):
    s = "{:.12g}".format(x)
    if '.' not in s and 'e' not in s and 'E' not in s:
        s += '.'
    return s

def parse_coords(s):
    return [c.strip() for c in s.split(',') if c.strip()]

def is_real(s):
    try:
        float(s); return True
    except ValueError:
        return False

def section(text, name):
    m = re.search(name + r";\s*(.*?)\s*ENDSEC;", text, re.DOTALL)
    return m.group(1) if m else ""

def split_statements(data):
    stmts, buf = [], []
    for line in data.splitlines():
        buf.append(line)
        if line.rstrip().endswith(';'):
            stmts.append('\n'.join(buf)); buf = []
    if buf:
        stmts.append('\n'.join(buf))
    return stmts

def parse_graph(statements):
    # entity_id -> set(referenced entity_ids); also collect component source reps.
    graph, source_reps = {}, set()
    for stmt in statements:
        m = re.match(r"\s*#(\d+)\s*=\s*([A-Z0-9_]+)", stmt)
        if m:
            eid = int(m.group(1))
        else:
            m2 = re.match(r"\s*#(\d+)\s*=\s*\(", stmt)  # complex entity, e.g. #427 = ( ... )
            eid = int(m2.group(1)) if m2 else None
        if eid is None:
            continue
        refs = set(int(x) for x in re.findall(r"#(\d+)", stmt))
        refs.discard(eid)
        graph[eid] = refs
        rr = RR_RE.search(stmt)
        if rr:
            source_reps.add(int(rr.group(1)))
    return graph, source_reps

def collect_local(graph, sources):
    # All entity ids reachable (downward) from component source reps. Their
    # CARTESIAN_POINTs are in component-local coords and must NOT be translated.
    seen, stack = set(), list(sources)
    while stack:
        e = stack.pop()
        if e in seen:
            continue
        seen.add(e)
        for r in graph.get(e, ()):
            if r not in seen:
                stack.append(r)
    return seen

def true_bbox(path):
    # Ground-truth board extent with component transforms applied (read-only).
    w = cq.importers.importStep(path)
    xs, ys, zs = [], [], []
    for v in w.vals():
        bb = v.BoundingBox()
        xs += [bb.xmin, bb.xmax]; ys += [bb.ymin, bb.ymax]; zs += [bb.zmin, bb.zmax]
    return (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))

texts = [open(p, 'r', errors='replace').read() for p in steps]
datas = [section(t, "DATA") for t in texts]
header = section(texts[0], "HEADER") if texts else ""

# Classify component-local points per file (for correct rigid translation).
local_sets = []
for d in datas:
    graph, sources = parse_graph(split_statements(d))
    local_sets.append(collect_local(graph, sources))

# True per-board bbox (OCCT, transforms applied) for tight layout.
bboxes = [true_bbox(p) for p in steps]

# Per-file entity-ID offsets so all references stay unique after merge.
offsets, running = [], 0
for d in datas:
    ids = [int(x) for x in re.findall(r"#(\d+)\s*=", d)]
    mid = max(ids) if ids else 0
    offsets.append(running)
    running += mid + 1

# Layout: side-by-side along X, centered on Y, sitting on Z=0.
trans, x_cursor = [], 0.0
for (x0, y0, z0, x1, y1, z1) in bboxes:
    dx = x_cursor - x0
    dy = -((y0 + y1) / 2.0)
    dz = -z0
    trans.append((dx, dy, dz))
    x_cursor += (x1 - x0) + gap_mm

def remap(data, off):
    return re.sub(r"#(\d+)", lambda m: "#" + str(int(m.group(1)) + off), data)

def translate(data, dx, dy, dz, local_ids):
    def repl(m):
        eid = int(re.match(r"#(\d+)", m.group(1)).group(1))
        if eid in local_ids:
            return m.group(0)  # component-local: placement transform moves it
        c = parse_coords(m.group(2))
        if len(c) != 3 or not all(is_real(v) for v in c):
            return m.group(0)
        pts = [fmt_real(float(c[0]) + dx), fmt_real(float(c[1]) + dy), fmt_real(float(c[2]) + dz)]
        return m.group(1) + ", ".join(pts) + m.group(3)
    return CPT_RE.sub(repl, data)

out = os.path.join(repo, "docs", "speek_assembly.step")
with open(out, 'w') as f:
    f.write("ISO-10303-21;\nHEADER;\n")
    f.write(header if header.endswith("\n") else header + "\n")
    f.write("ENDSEC;\nDATA;\n")
    for d, off, (dx, dy, dz), loc in zip(datas, offsets, trans, local_sets):
        f.write(remap(translate(d, dx, dy, dz, loc), off))
        f.write("\n")
    f.write("ENDSEC;\nEND-ISO-10303-21;\n")
print(f"Wrote {out}")
PY
else
    echo "warning: skipping assembly STEP (missing per-board STEPs or uv not found)" >&2
fi

echo ">> banner"
STITCH="$(command -v magick || command -v convert)"
tiles=()
for entry in "${BOARDS[@]}"; do
    IFS='|' read -r slug _ _ <<<"$entry"
    [[ -f "$IMG_DIR/_banner_${slug}.png" ]] && tiles+=("$IMG_DIR/_banner_${slug}.png")
done
"$STITCH" "${tiles[@]}" -trim +repage -background none -gravity center +append \
    -background white -flatten "$IMG_DIR/banner.png"
rm -f "${tiles[@]}"

python3 - "$REPO_ROOT" <<'PY'
import csv, os, sys
from urllib.parse import quote

repo = sys.argv[1]
readme_path = os.path.join(repo, "README.md")
GH_TREE = "https://github.com/JBlitzar/speek/tree/main"

BOARDS = [
    ("amp", "speek-amp", "speek_amp", "Speek Amp"),
    ("rx",  "speek-rx",  "speek_rx",  "Speek RX"),
    ("psu", "speek-psu", "speek_psu", "Speek PSU"),
]

def img(rel):
    return rel if os.path.isfile(os.path.join(repo, rel)) else None

def kicanvas(board_dir, base):
    url = f"{GH_TREE}/{board_dir}/PCB/{base}"
    return f"https://kicanvas.org/?repo={quote(url, safe='')}"

def csv_to_md(path):
    if not os.path.isfile(path):
        return None
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    if not rows:
        return None
    header, body = rows[0], [r for r in rows[1:] if any(c.strip() for c in r)]
    ncol = len(header)
    def fmt(cells):
        cells = (list(cells) + [""] * ncol)[:ncol]
        return "| " + " | ".join(c.replace("|", r"\|").replace("\n", " ").strip() for c in cells) + " |"
    return "\n".join([fmt(header), "| " + " | ".join(["---"] * ncol) + " |"] + [fmt(r) for r in body])

gallery, schem, pcbs = [], [], []
for slug, d, b, name in BOARDS:
    kc_link = kicanvas(d, b)

    if img(f"docs/{slug}_3d.png"):
        gallery.append(f"### {name}\n\n![{name} 3D render](docs/{slug}_3d.png)")

    if img(f"docs/{slug}_schematic.png"):
        schem.append(f"### {name}\n\n[View on KiCanvas]({kc_link})\n\n"
                     f"![{name} schematic](docs/{slug}_schematic.png)")

    f_p, b_p = img(f"docs/{slug}_fcu.png"), img(f"docs/{slug}_bcu.png")
    if f_p or b_p:
        pcbs.append(f"### {name}\n\n[View on KiCanvas]({kc_link})\n\n"
                    f"| F.Cu | B.Cu |\n| --- | --- |\n"
                    f"| ![{name} F.Cu]({f_p or ''}) | ![{name} B.Cu]({b_p or ''}) |")

fab = []
for slug, d, b, name in BOARDS:
    md = csv_to_md(os.path.join(repo, d, "PCB", b, "production_real", f"{b}_1_bom.csv"))
    if md:
        fab.append(f"### {name}\n\n{md}")

overall = csv_to_md(os.path.join(repo, "BOM.csv"))

sections = {
    "## Gallery": "\n\n".join(gallery) or "_No 3D renders generated yet._",
    "## Schematics": "\n\n".join(schem) or "_No schematics generated yet._",
    "## PCBs": "\n\n".join(pcbs) or "_No PCB layer images generated yet._",
    "## Overall BOM": overall or "_No BOM.csv found._",
    "## Fabrication BOMs": "\n\n".join(fab) or "_No fabrication BOMs found._",
}

with open(readme_path) as f:
    lines = f.read().split("\n")

lines = [l for l in lines if "docs/banner.png" not in l]
if img("docs/banner.png"):
    for idx, l in enumerate(lines):
        if l.startswith("# ") and not l.startswith("## "):
            lines[idx+1:idx+1] = ["", "![speek](docs/banner.png)"]
            break
    else:
        lines = ["![speek](docs/banner.png)", ""] + lines

GEN_PREFIXES = ("### ", "|", "![", "[View on KiCanvas]", "_No")

def is_heading(line):
    return line.lstrip().startswith("## ") or (line.startswith("# ") and not line.startswith("## "))

def replace_section(lines, heading, content):
    out, i, n = [], 0, len(lines)
    while i < n:
        out.append(lines[i])
        if lines[i].strip() == heading:
            i += 1
            preamble = []
            while i < n and not is_heading(lines[i]) \
                    and not lines[i].lstrip().startswith(GEN_PREFIXES):
                preamble.append(lines[i])
                i += 1
            while i < n and not is_heading(lines[i]):
                i += 1
            while preamble and not preamble[0].strip():
                preamble.pop(0)
            while preamble and not preamble[-1].strip():
                preamble.pop()
            out += [""] + (preamble + [""] if preamble else []) + [content, ""]
            continue
        i += 1
    return out

for heading, content in sections.items():
    if any(l.strip() == heading for l in lines):
        lines = replace_section(lines, heading, content)
    else:
        lines += ["", heading, "", content, ""]

result, blanks = [], 0
for l in lines:
    blanks = blanks + 1 if l.strip() == "" else 0
    if blanks <= 1:
        result.append(l)

with open(readme_path, "w") as f:
    f.write("\n".join(result).rstrip() + "\n")

print("README.md updated.")
PY

echo "Done. Images in $IMG_DIR"
