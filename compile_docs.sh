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
    local svg="$1" png="$2" width="${3:-1800}"
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$width" -b white "$svg" -o "$png"
    elif command -v inkscape >/dev/null 2>&1; then
        inkscape "$svg" --export-type=png --export-width="$width" \
            --export-background=white --export-filename="$png" >/dev/null 2>&1
    elif command -v magick >/dev/null 2>&1; then
        magick -density 200 -background white -flatten "$svg" "$png"
    else
        convert -density 200 -background white -flatten "$svg" "$png"
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
    svg2png "$IMG_DIR/${slug}_fcu.svg" "$IMG_DIR/${slug}_fcu.png"
    rm -f "$IMG_DIR/${slug}_fcu.svg"

    echo ">> $slug: B.Cu"
    "$KICAD_CLI" pcb export svg --output "$IMG_DIR/${slug}_bcu.svg" --mode-single \
        --layers B.Cu,B.Silkscreen,B.Mask,Edge.Cuts --mirror \
        --page-size-mode 2 --exclude-drawing-sheet "$pcb" >/dev/null
    svg2png "$IMG_DIR/${slug}_bcu.svg" "$IMG_DIR/${slug}_bcu.png"
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
done

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
