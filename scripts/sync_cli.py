"""Keep the self-contained installer CLI identical to the standalone buds file."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
installer = root / "install.sh"
text = installer.read_text(encoding="utf-8")

start_marker = '    cat <<\'BUDS_CLI_EOF\' > "$BUDS_CLI"\n'
end_marker = "\nBUDS_CLI_EOF\n"

start = text.index(start_marker) + len(start_marker)
end = text.index(end_marker, start)
buds_content = (root / "buds").read_text(encoding="utf-8").rstrip("\n")
updated = text[:start] + buds_content + text[end:]
shared = buds_content[buds_content.index("record_firewall_rule() {"):buds_content.index("cleanup_firewall() {")]
left = updated.index("record_firewall_rule() {")
right = updated.index("start_service() {", left)
updated = updated[:left] + shared + updated[right:]

if "--check" in sys.argv:
    if text != updated:
        print("Embedded CLI differs; run: python scripts/sync_cli.py", file=sys.stderr)
        sys.exit(1)
    print("OK: install.sh and buds CLI are in sync.")
else:
    installer.write_text(updated, encoding="utf-8", newline="\n")
    print("Synchronized buds -> install.sh successfully.")
