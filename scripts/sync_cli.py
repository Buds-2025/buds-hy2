"""Keep the self-contained installer CLI identical to the standalone buds file."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
installer = root / "install.sh"
text = installer.read_text(encoding="utf-8")

start_marker = '        cat <<\'EOF\' > "$BUDS_CLI"\n'
end_marker = "\nEOF\n    fi\n"

if start_marker not in text or end_marker not in text:
    # Try legacy format if not yet adapted
    legacy_start = '    cat <<\'EOF\' > "$BUDS_CLI"\n'
    legacy_end = "\nEOF\n    chmod +x \"$BUDS_CLI\"\n"
    if legacy_start in text and legacy_end in text:
        start_marker = legacy_start
        end_marker = legacy_end

start = text.index(start_marker) + len(start_marker)
end = text.index(end_marker, start)
buds_content = (root / "buds").read_text(encoding="utf-8").rstrip("\n")
updated = text[:start] + buds_content + text[end:]

if "--check" in sys.argv:
    if text != updated:
        print("Embedded CLI differs; run: python scripts/sync_cli.py", file=sys.stderr)
        sys.exit(1)
    print("OK: install.sh and buds CLI are in sync.")
else:
    installer.write_text(updated, encoding="utf-8", newline="\n")
    print("Synchronized buds -> install.sh successfully.")
