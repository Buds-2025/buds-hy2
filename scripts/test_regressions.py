"""Targeted HY2 regressions using temporary files and mocked system commands.

Run: python scripts/test_regressions.py (Python 3 and Bash required).
"""
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
OPENSSL = shutil.which("openssl")
if os.name == "nt":
    BASH = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")
    OPENSSL = str(Path(BASH).parents[1] / "usr/bin/openssl.exe")


class Regressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="buds-hy2-regression-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.sandbox = self.directory.as_posix()
        if os.name == "nt":
            self.sandbox = subprocess.check_output(
                [BASH, "-c", 'cygpath -u "$1"', "test", str(self.directory)], text=True
            ).strip()
        self.config = self.directory / "etc/hysteria"
        self.config.mkdir(parents=True)
        (self.directory / "run").mkdir()
        self.sources = {}
        for name in ("buds", "install.sh"):
            source = (ROOT / name).read_text(encoding="utf-8")
            source = source.rsplit('\nmain "$@"', 1)[0] if name == "install.sh" else source.rsplit("\ncheck_root\n", 1)[0]
            # Redirect absolute runtime paths before loading the real function definitions.
            for prefix in ("/etc/", "/usr/local/", "/var/log/", "/run/"):
                source = source.replace(prefix, self.sandbox + prefix)
            self.sources[name] = source

    def shell(self, script, source="buds", expected=0, timeout=15):
        prelude = f"""
set -eo pipefail
SANDBOX={shlex.quote(self.sandbox)}
ACTION_FILE="$SANDBOX/actions"
: > "$ACTION_FILE"
info() {{ :; }}
success() {{ :; }}
warn() {{ echo "WARN: $*"; }}
error() {{ echo "ERROR: $*"; }}
chown() {{ :; }}
setcap() {{ echo "setcap $*" >> "$ACTION_FILE"; }}
systemctl() {{ echo "systemctl $*" >> "$ACTION_FILE"; }}
rc-service() {{ echo "rc-service $*" >> "$ACTION_FILE"; }}
rc-update() {{ echo "rc-update $*" >> "$ACTION_FILE"; }}
openrc-run() {{ :; }}
pkill() {{ echo "pkill $*" >> "$ACTION_FILE"; }}
killall() {{ echo "killall $*" >> "$ACTION_FILE"; }}
nginx() {{ echo "nginx $*" >> "$ACTION_FILE"; }}
sleep() {{ :; }}
"""
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-s"],
            input=self.sources[source] + "\n" + prelude + script,
            text=True, encoding="utf-8", capture_output=True, timeout=timeout,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def actions(self):
        return (self.directory / "actions").read_text(encoding="utf-8")

    def test_nodes_menu_dispatches_all_actions_and_requires_matching_delete_confirmation(self):
        edits = [
            ("1\nproxy.example.org\ny", "--domain proxy.example.org"),
            ("2\n3443:3474\ny", "--ports 3443:3474"),
            ("3\nsame\ny", "--public-ports same"),
            ("4\ny", "--auth random --obfs random"),
            ("5\n1", "--auth custom"), ("5\n2", "--obfs custom"),
            ("5\n3\ny", "--auth random"), ("5\n4\ny", "--obfs random"),
            ("6\nhttps://example.org/\ny", "--masquerade https://example.org/"),
            ("7\nself\ny", "--tls self"),
        ]
        entries = ["1", "2\nfailed", "2\ntaken\nwork",
                   "3\n999\n1", "4\n2", "5\n2", "6\n2", "7\n2", "8\n2\ny", "9\n2\ny",
                   "10\n2\n" + "\n\n".join(keys for keys, _ in edits) + "\n\n0",
                   "11\n1\nwrong", "11\n1\nwork", "12", "13", "14", "0"]
        # Each completed action pauses exactly once. Leaving the edit screen returns directly.
        keys = "\n\n".join(entries[:10]) + "\n\n" + entries[10] + "\n" + "\n\n".join(entries[11:])
        out = self.shell(r'''nodes_manage() {
  echo "$*" >> "$ACTION_FILE"
  case "$1" in
    list) echo '节点列表结果' ;;
    names) printf '%s\n' main work ;;
    quick-add) case "$2" in taken) return 3 ;; failed) return 1 ;; esac ;;
  esac
}
renew_test() { echo renew >> "$ACTION_FILE"; }
log() { echo live >> "$ACTION_FILE"; }
uninstall() { echo uninstall >> "$ACTION_FILE"; return 1; }
panel_clear() { echo '<刷新>'; }
panel_pause() { echo "按回车返回$1"; read -r ignored; }
nodes_menu <<'INPUT'
''' + keys + "\nINPUT\n")
        self.assertIn("节点列表结果\n按回车返回A 区\n<刷新>", out)
        self.assertIn("新增未完成", out)
        self.assertIn("已取消删除", out)
        self.assertIn("请从列表中选择一个节点编号", out)
        self.assertEqual([a for a in self.actions().splitlines() if a not in ("names", "detail work", "port-guide work")], [
            "list", "quick-add failed", "quick-add taken", "quick-add work", "link work",
            "link main", "client work", "status work", "log work", "start work", "stop work", "restart work",
            *["edit work " + args for _, args in edits],
            "delete work --yes", "renew", "live", "uninstall",
        ])

    def test_home_lists_both_sections_and_requires_a_letter_before_dispatch(self):
        output = self.shell(r'''check_remote_version() { echo "$SCRIPT_VERSION"; }
nodes_menu() { echo A >> "$ACTION_FILE"; }
warp_menu() { echo B >> "$ACTION_FILE"; }
update_script() { echo U >> "$ACTION_FILE"; return 1; }
show_menu <<'INPUT'
1
11
12
8
a
B
A
b
u
0
INPUT
''')
        self.assertEqual(self.actions().splitlines(), ["A", "B", "A", "B", "U"])
        self.assertEqual(output.count("请先输入 A 或 B"), 4)
        nodes = output.split("A 节点管理", 1)[1].split("B WARP 分流管理", 1)[0]
        warp = output.split("B WARP 分流管理", 1)[1].split("U. 更新脚本", 1)[0]
        for menu, n in ((nodes, 14), (warp, 13)):
            self.assertEqual(list(map(int, re.findall(r"\b(\d+)\. ", menu))), list(range(1, n + 1)))

    def test_panel_logo_and_numbered_grid_at_different_widths(self):
        import unicodedata
        def cells(line):
            return sum(2 if unicodedata.east_asian_width(char) in ("F", "W") else 1 for char in line)

        for width, columns in ((32, 1), (38, 1), (52, 2), (80, 3), (120, 3)):
            with self.subTest(width=width):
                output = self.shell(f"COLUMNS={width}\nw=$(panel_width)\npanel_logo \"$w\"\necho '---'\nnodes_options \"$w\"\n")
                logo, menu = output.split("---\n")
                self.assertNotIn("\x1b", output)
                self.assertIn("✧", logo)
                self.assertIn("✦", logo)
                self.assertIn("█▀▀█ █  █ █▀▀▄ █▀▀▀", logo)
                self.assertIn("█  █ █  █ █▀▀█", logo)
                self.assertEqual("High-Performance Protocol Suite" in logo, width >= 52)
                self.assertEqual(len(logo.splitlines()), 10 if width < 38 else 6)
                self.assertLessEqual(max(map(cells, output.splitlines())), width)
                self.assertEqual(len(menu.splitlines()), (14 + columns - 1) // columns)
                for line in menu.splitlines():
                    # Numbers are right-aligned so their periods share a column.
                    ends = [cells(line[:m.end()]) for m in re.finditer(r"\d+\.", line)]
                    self.assertEqual(ends, [4 + i * 26 for i in range(len(ends))])

    def test_update_success_reopens_installed_cli_and_confirmed_uninstall_exits(self):
        self.shell(r'''check_remote_version() { echo "$SCRIPT_VERSION"; }
update_script() { echo updated >> "$ACTION_FILE"; }
mkdir -p "$(dirname "$BUDS_CLI")"
printf '#!/usr/bin/env bash\necho "reopen $1" >> "%s"\n' "$ACTION_FILE" > "$BUDS_CLI"
chmod +x "$BUDS_CLI"
show_menu <<< U
''')
        self.assertEqual(self.actions().splitlines(), ["updated", "reopen hy2"])
        self.shell("uninstall() { echo removed >> \"$ACTION_FILE\"; }\nnodes_menu <<< 14\necho unexpected >> \"$ACTION_FILE\"\n")
        self.assertEqual(self.actions().splitlines(), ["removed"])

    def node_manager(self, primary_public="443"):
        source = (ROOT / "buds").read_text(encoding="utf-8")
        source = source.split("nodes_source() {\n    cat <<'PY'\n", 1)[1].split("\ntry:\n    main()", 1)[0]
        manager = {}
        with patch.object(sys, "argv", ["nodes", str(self.config), "443", primary_public, "proxy.example.com"]):
            with patch.dict(sys.modules, {name: ModuleType(name) for name in ("grp", "pwd")}):
                exec(compile(source, "buds:nodes_source", "exec"), manager)
        return manager

    def test_quick_add_retries_invalid_fields_and_only_asks_for_public_mapping_when_needed(self):
        for public, answers, expected_public in [
            ("443", ["a" * 64 + ".net", "", "0", "32000"], "32000"),
            ("30443", ["https://broken", "proxy.example.com", "32000:32003", "30443", "42000-42003"], "42000-42003"),
        ]:
            with self.subTest(public=public):
                manager = self.node_manager(public)
                manager["UNITS"] = self.directory / "units"
                manager["port_conflicts"] = lambda _: ([], [((int(public), int(public)), "main")])
                manager["check_hopping"] = lambda _: None
                with patch("builtins.input", side_effect=answers) as read:
                    with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                        saved = manager["quick_add_preferences"]("alpha")
                self.assertEqual(read.call_count, len(answers))
                self.assertEqual(saved.domain, "proxy.example.com")
                self.assertEqual(saved.public_ports, expected_public)
                self.assertEqual((saved.auth, saved.obfs, saved.tls), ("random", "random", None))

    def test_nodes_reserve_the_entire_range_and_reject_unsafe_hopping_versions(self):
        manager = self.node_manager()
        choose_ports = manager["choose_ports"]
        reservations = [((20000, 30002), "first node"), ((30006, 60999), "second node")]
        self.assertEqual(choose_ports("auto:3", reservations), (30003, 30005))
        with self.assertRaisesRegex(ValueError, "second node"):
            choose_ports("30003-30006", reservations)
        with self.assertRaisesRegex(ValueError, "未找到可用端口"):
            choose_ports("auto:4", reservations)
        manager["run"] = lambda *args: SimpleNamespace(stdout="Version:\tv2.12.2\n")
        manager["check_hopping"]((30003, 30003))
        with self.assertRaisesRegex(ValueError, "2.12.3"):
            manager["check_hopping"]((30003, 30005))

    def test_primary_edit_rolls_back_and_preserves_custom_settings_and_stopped_state(self):
        self.node_config(public="443", local="443")
        server = self.config / "config.yaml"
        client = self.config / "client.yaml"
        server.write_text(server.read_text() + '# keep local policy\nacl:\n  inline: ["reject(127.0.0.1)"]\n')
        client.write_text(client.read_text() + 'auth: "test-password"\nobfs:\n  salamander:\n    password: "test-obfs"\n')
        manager = self.node_manager()
        unit = self.directory / "hysteria-server.service"
        unit.write_text("[Service]\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n")
        manager["UNITS"] = self.directory
        changes = []
        def run(*args, **kwargs):
            changes.append(args)
            return SimpleNamespace(stdout="argv[]=/usr/local/bin/hysteria server --config " + str(server) + " ;")
        manager.update(run=run, active=lambda _: True, check_hopping=lambda _: None,
                       port_conflicts=lambda _: ([((45000, 45031), "其他节点")], []),
                       primary_firewall=lambda *args: changes.append((args[0], args[-1])))
        args = SimpleNamespace(tls=None, domain=None, masquerade=None, ports="45000", public_ports=None, auth="random", obfs="random")
        with self.assertRaisesRegex(ValueError, "其他节点"):
            manager["edit_primary"](args)
        args.ports = "41000:41031"
        def start(data):
            changes.append(("start", data["ports"]))
            if data["ports"] != "443":
                raise ValueError("启动验证失败")
        manager["start_node"] = start
        before = [p.read_bytes() for p in (server, client, unit)]
        with patch.object(os, "fchown", create=True), patch.object(os, "fchmod", create=True):
            with self.assertRaisesRegex(ValueError, "启动验证失败"):
                manager["edit_primary"](args)
            self.assertEqual(before, [p.read_bytes() for p in (server, client, unit)])
            self.assertFalse((self.config / ".public_port").exists())
            self.assertIn(("start", "443"), changes)
            changes.clear()
            manager["active"] = lambda _: False
            with redirect_stdout(StringIO()):
                manager["edit_primary"](args)
            self.assertNotIn(("start", "41000-41031"), changes)
            self.assertIn('"CAP_NET_ADMIN"', json.dumps(unit.read_text().split("=")[-1].split()))
            self.assertIn('# keep local policy\nacl:', server.read_text())
            self.assertIn('server: "proxy.example.com:41000-41031"', client.read_text())
            self.assertNotIn('test-password', client.read_text())
            self.assertEqual((self.config / ".public_port").read_text().strip(), "41000-41031")
            manager.update(PRIMARY_LISTEN="41000-41031", PRIMARY_PUBLIC="41000-41031", active=lambda _: True)
            args.ports, args.public_ports, args.auth, args.obfs = None, "42000-42031", "keep", "keep"
            changes.clear()
            with redirect_stdout(StringIO()):
                manager["edit_primary"](args)
            self.assertFalse(any("stop" in call or "start" in call or "open" in call for call in changes))
            self.assertEqual((self.config / ".public_port").read_text().strip(), "42000-42031")

    def test_primary_appears_in_node_picker_and_can_show_ports_without_applying(self):
        output = self.shell('''
nodes_manage() {
    echo "$*" >> "$ACTION_FILE"
    case "$1" in names) printf '%s\\n' main work ;; port-guide) echo '本机可选范围' ;; esac
}
nodes_menu <<'INPUT'
10
1
2
auto:32
n
0
0
0
INPUT
''')
        self.assertIn("main（主节点）", output)
        self.assertIn("本机可选范围", output)
        self.assertIn("port-guide main", self.actions())
        self.assertNotIn("edit main", self.actions())

    def test_uninstall_preserves_existing_secondary_nodes(self):
        node = self.config / "nodes/personal"
        node.mkdir(parents=True)
        metadata = node / "node.json"
        metadata.write_text('{}', encoding="utf-8")
        self.shell("uninstall <<<'y'\n", expected=1)
        self.assertEqual(metadata.read_text(encoding="utf-8"), '{}')
        self.assertEqual(self.actions(), "")

    def test_warp_domain_policy_and_profile_import(self):
        profile = self.directory / "wgcf.conf"
        profile.write_text("[Interface]\nAddress=172.16.0.2/32\nAddress=fd42::2/128\n"
                           "PrivateKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
                           "PostUp=touch injected\n[Peer]\nEndpoint=[2001:db8::1]:2408\n"
                           "PublicKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=\n"
                           "AllowedIPs=0.0.0.0/0, ::/0\n")
        python = shlex.quote(Path(sys.executable).as_posix())
        self.shell(f'python3() {{ {python} -X utf8 "$@"; }}\n' + """
cd "$SANDBOX"
warp_domains > domains
warp_config wgcf.conf domains 1.13.0 > split.json
""")
        config = json.loads((self.directory / "split.json").read_text())
        dns_rule = config["dns"]["rules"][0]
        domains = set(dns_rule["domain_suffix"])
        for host in ("play.google.com", "scholar.google.co.uk", "gemini.google.com", "www.youtube.com",
                     "video.googlevideo.com", "gemini.app.google", "notebooklm.google", "antigravity.google"):
            self.assertTrue(any(host == d or host.endswith("." + d) for d in domains), host)
        for host in ("x.com", "github.com", "google.com.example.org", "chatgpt.com", "openai.com",
                     "cdn.oaistatic.com", "api.anthropic.com", "claude.ai", "claude.com"):
            self.assertFalse(any(host == d or host.endswith("." + d) for d in domains), host)
        self.assertEqual(set(dns_rule["query_type"]), {"A", "AAAA"})
        self.assertEqual(config["route"]["rules"][-1]["action"], "reject")
        self.assertFalse(config["inbounds"][0]["auto_route"])
        wg = config["endpoints"][0]
        self.assertFalse(wg["system"])
        self.assertEqual(wg["address"], ["172.16.0.2/32", "fd42::2/128"])
        self.assertEqual(wg["peers"][0]["address"], "2001:db8::1")
        self.assertFalse((self.directory / "injected").exists())
        if os.environ.get("BUDS_TEST_SING_BOX"):
            subprocess.run([os.environ["BUDS_TEST_SING_BOX"], "check", "-c", "split.json"],
                           cwd=self.directory, check=True, capture_output=True)

    def test_warp_cleanup_preserves_foreign_unit(self):
        self.shell("""
mkdir -p "$WARP_DIR"
touch "$WARP_DIR/config.json" "$WARP_DIR/.buds-managed"
systemctl() { echo "$*" >> "$ACTION_FILE"; echo loaded; }
if warp_remove; then exit 9; fi
test -e "$WARP_DIR/config.json"
""")
        self.assertNotIn("disable", self.actions())
        self.assertNotIn("stop", self.actions())

    def test_warp_policy_migrates_old_install_and_renders_empty_policy(self):
        python = shlex.quote(Path(sys.executable).as_posix())
        self.shell(f'python3() {{ {python} -X utf8 "$@"; }}\n' + """
umask 077
mkdir -p "$WARP_DIR"
cd "$WARP_DIR"
touch .buds-managed
echo 'google.com chatgpt.com' > domains
cat > legacy.conf <<'WG'
[Interface]
Address=172.16.0.2/32
PrivateKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
[Peer]
PublicKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=
Endpoint=192.0.2.1:2408
AllowedIPs=0.0.0.0/0
WG
warp_config legacy.conf domains 1.13.0 > config.json
warp_prepare_policy
python3 policy.py render base.json ../warp-domains .
grep -Fxq chatgpt.com domains
warp_domains > "$WARP_LIST"
python3 policy.py render base.json ../warp-domains .
if grep -Fxq chatgpt.com domains; then exit 9; fi
grep -Fxq google.com domains
: > "$WARP_LIST"
python3 policy.py render base.json ../warp-domains .
bash link-up
test ! -s domains
""")
        root = self.directory / "etc/buds-hy2/warp-split"
        backup = json.loads((root / "base.json").read_text())
        config = json.loads((root / "config.json").read_text())
        self.assertEqual(backup["endpoints"], config["endpoints"])
        self.assertEqual(config["route"]["rules"], [{"action": "reject"}])
        if os.environ.get("BUDS_TEST_SING_BOX"):
            subprocess.run([os.environ["BUDS_TEST_SING_BOX"], "check", "-c", "config.json"],
                           cwd=root, check=True, capture_output=True)

    def test_warp_gemini_family_only_changes_selected_names_and_requires_tunnel_family(self):
        python = shlex.quote(Path(sys.executable).as_posix())
        self.shell(f'python3() {{ {python} -X utf8 "$@"; }}\n' + """
cd "$SANDBOX"
warp_policy_tool > policy.py
cat > fixture.conf <<'WG'
[Interface]
Address=172.16.0.2/32, fd42::2/128
PrivateKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
[Peer]
PublicKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=
Endpoint=192.0.2.1:2408
AllowedIPs=0.0.0.0/0, ::/0
WG
printf '%s\\n' google.com gstatic.com > selected
printf '%s\\n' ipv6 > family
warp_config fixture.conf selected 1.13.0 > base.json
python3 policy.py render base.json selected . family
cp config.json restricted.json
printf '%s\\n' gstatic.com > selected
python3 policy.py render base.json selected . family
cp config.json excluded.json
sed 's/, ::\\/0//' fixture.conf > ipv4.conf
printf '%s\\n' google.com > selected
warp_config ipv4.conf selected 1.13.0 > ipv4.json
if python3 policy.py render ipv4.json selected . family; then exit 9; fi
""")
        config = json.loads((self.directory / "restricted.json").read_text())
        route = config["route"]["rules"]
        resolves = [rule for rule in route if rule["action"] == "resolve"]
        self.assertEqual(resolves[0]["strategy"], "ipv6_only")
        self.assertEqual(set(resolves[0]["domain_suffix"]), {"gemini.google.com", "geminiweb-pa.clients6.google.com"})
        self.assertEqual(resolves[1]["strategy"], "prefer_ipv4")
        self.assertEqual(route[route.index(resolves[0]) + 1], {
            "domain_suffix": resolves[0]["domain_suffix"], "action": "route", "outbound": "warp"})
        self.assertEqual(config["dns"]["rules"][0], {
            "inbound": "split", "domain_suffix": resolves[0]["domain_suffix"], "query_type": ["A"],
            "action": "predefined", "rcode": "NOERROR"})
        self.assertEqual(resolves[1]["domain_suffix"], ["google.com", "gstatic.com"])
        excluded = json.loads((self.directory / "excluded.json").read_text())["route"]["rules"]
        self.assertFalse(any(rule.get("strategy") == "ipv6_only" for rule in excluded))
        if os.environ.get("BUDS_TEST_SING_BOX"):
            subprocess.run([os.environ["BUDS_TEST_SING_BOX"], "check", "-c", "restricted.json"],
                           cwd=self.directory, check=True, capture_output=True)

    def test_warp_checks_competing_resolved_domains(self):
        python = shlex.quote(Path(sys.executable).as_posix())
        out = self.shell(f'python3() {{ {python} -X utf8 "$@"; }}\n' + """
cd "$SANDBOX"
warp_policy_tool > policy.py
printf '%s\n' team.example.com > domains
printf '%s\n' 'Global: ~. example.com' 'Link 3 (vpn0): ~other.example.com' \
    'Link 4 (buds-warp0): ~team.example.com' | python3 -I policy.py check-resolved domains
for conflict in 'Global: ~TEAM.EXAMPLE.COM.' 'Link 3 (vpn0): team.example.com' \
    'Link 3 (vpn0): ~branch.team.example.com'; do
    if printf '%s\n' "$conflict" | python3 -I policy.py check-resolved domains 2>&1; then exit 9; fi
done
if printf '%s\n' 'Global: ~.' 'Link 3 (vpn0):' '     ~branch.team.example.com' \
    | python3 -I policy.py check-resolved domains 2>&1; then exit 9; fi
""")
        self.assertEqual(out.count("DNS 路由域冲突"), 4)

    def test_warp_finds_a_manual_sing_box_installation_outside_path(self):
        self.shell("""
mkdir -p "$SANDBOX/etc/s-box"
cat > "$SANDBOX/etc/s-box/sing-box" <<'SING_BOX'
#!/usr/bin/env bash
echo 'sing-box version 1.14.2'
SING_BOX
chmod 755 "$SANDBOX/etc/s-box/sing-box"
warp_exec_safe() { :; }
systemctl() { echo 0; }
found=$(warp_find_binary)
[[ "$found" == "$SANDBOX/etc/s-box/sing-box 1.14.2" ]]
""")

    @unittest.skipUnless(os.name == "posix", "requires filesystem symlinks")
    def test_warp_dns_switch_and_restore_preserve_the_static_resolver(self):
        self.shell("""
mkdir -p "$(dirname "$WARP_STUB")"
printf '%s\n' 'nameserver 127.0.0.53' > "$WARP_STUB"
printf '%s\n' '# original' 'nameserver 8.8.8.8' 'nameserver 8.8.4.4' > "$SANDBOX/etc/resolv.conf"
cp "$SANDBOX/etc/resolv.conf" "$SANDBOX/original"
timeout() { return "$DNS_TEST_RESULT"; }
DNS_TEST_RESULT=1
if warp_dns_switch; then exit 9; fi
cmp "$SANDBOX/etc/resolv.conf" "$SANDBOX/original"
[[ ! -e "$WARP_DNS_DROPIN" && ! -e "$WARP_DNS_STATE" ]]
DNS_TEST_RESULT=0
warp_dns_switch
[[ $(readlink "$SANDBOX/etc/resolv.conf") == "$WARP_STUB" ]]
grep -Fx 'DNS=8.8.8.8 8.8.4.4' "$WARP_DNS_DROPIN"
warp_dns_restore
cmp "$SANDBOX/etc/resolv.conf" "$SANDBOX/original"
[[ ! -e "$WARP_DNS_DROPIN" && ! -e "$WARP_DNS_STATE" ]]
""")

    def test_warp_trace_detects_swapped_exits(self):
        self.shell("""
mkdir -p "$WARP_DIR"
echo chatgpt.com > "$WARP_DIR/domains"
curl() { case "${!#}" in *chatgpt.com/*) echo warp=on ;; *) echo warp=off ;; esac; }
warp_trace
curl() { echo warp=off; }
if warp_trace; then exit 9; fi
echo google.com > "$WARP_DIR/domains"
warp_trace
""")

    def test_warp_menu_keeps_options_available_after_cancellation_and_failure(self):
        output = self.shell(r'''
systemctl() { return 1; }
warp_manage() {
    printf '%s\n' "$*" >> "$ACTION_FILE"
    [[ "$1" != check ]]
}
warp_menu_begin() { echo wizard >> "$ACTION_FILE"; }
warp_menu <<'INPUT'
1
2
3
1
2
example.org one.test
3
example.org
4
one.test
two.test
5
/tmp/example
n
5
/tmp/example
y
6
n
6
y
0
4
ipv6
5
n
5
y
6
7
8
9
10
11
n
11
y
12
n
12
y
13

0
INPUT
''')
        self.assertIn("已取消 DNS 迁移", output)
        self.assertIn("已取消关闭", output)
        self.assertIn("已取消 DNS 恢复", output)
        self.assertEqual(self.actions().splitlines(), [
            "wizard", "check", "domains list", "domains add example.org one.test",
            "domains remove example.org", "domains replace one.test two.test",
            "domains import /tmp/example", "domains reset", "gemini-family", "gemini-family ipv6",
            "disable", "doctor", "status", "setup", "setup --managed-core", "setup --new-profile",
            "dns-switch", "dns-restore", "enable ",
        ])

    def test_warp_wizard_reverts_only_dns_it_changed_for_this_attempt(self):
        self.shell(r"""
systemctl() { return 1; }
warp_requirements() { [[ "$1" == before-dns ]]; }
warp_check_stub() { return "$STUB_STATUS"; }
warp_manage() {
    echo "$*" >> "$ACTION_FILE"
    if [[ "$1" == enable ]]; then return 1; fi
}
STUB_STATUS=1
if warp_menu_begin <<< y; then exit 9; fi
STUB_STATUS=0
if warp_menu_begin; then exit 9; fi
""")
        self.assertEqual(self.actions().splitlines(),
                         ["setup", "dns-switch", "enable", "dns-restore", "setup", "enable"])

    def test_warp_requires_exclusive_stub(self):
        self.shell("""
resolv="$SANDBOX/etc/resolv.conf"
printf '%s\n' '#nameserver 9.9.9.9' '  nameserver 127.0.0.53' > "$resolv"
warp_check_stub
printf '%s\n' 'nameserver 9.9.9.9' 'options rotate' >> "$resolv"
if warp_check_stub; then exit 9; fi
: > "$resolv"
if warp_check_stub; then exit 9; fi
""")

    def test_warp_tunnel_probe_requires_confirmed_exit(self):
        self.shell("""
mkdir -p "$WARP_DIR"
echo custom.example > "$WARP_DIR/domains"
curl() {
    [[ " $* " == *' --resolve one.one.one.one:443:198.18.240.3 '* ]] || return 1
    printf '%s\r\n' "$response"
}
response=warp=on
warp_tunnel_probe
response=warp=off
if warp_tunnel_probe; then exit 9; fi
response=
if warp_tunnel_probe; then exit 9; fi
: > "$WARP_DIR/domains"
warp_tunnel_probe
""")

    def test_warp_partial_install_cleanup_is_retryable(self):
        self.shell("""
mkdir -p "$WARP_DIR"
touch "$WARP_DIR/config.json" "$WARP_DIR/.buds-managed" "$WARP_DIR/unrelated"
systemctl() { if [[ "$1" == show ]]; then echo not-found; fi; }
if warp_remove; then exit 9; fi
test -f "$WARP_DIR/unrelated" && test -f "$WARP_DIR/.buds-managed"
rm "$WARP_DIR/unrelated"
warp_remove
test ! -e "$WARP_DIR"
warp_remove
""")

    def test_warp_rollback_clears_only_start_rate_limit(self):
        python = shlex.quote(Path(sys.executable).as_posix())
        for result in ("start-limit-hit", "exit-code"):
            with self.subTest(result=result):
                output = self.shell(f'PYTHON_BIN={python}\nRESULT={result}\n' + """
mkdir -p "$WARP_DIR" "$SANDBOX/etc/systemd/system"
touch "$WARP_DIR/.buds-managed" "$WARP_DIR/$WARP_UNIT"
ln -f "$WARP_DIR/$WARP_UNIT" "$SANDBOX/etc/systemd/system/$WARP_UNIT"
echo previous.example > "$WARP_LIST"
cp "$WARP_LIST" "$WARP_DIR/domains"
warp_prepare_policy() { :; }
warp_runtime_binary() { echo sing-box; }
python3() {
    case " $* " in *"policy.py render "*) return 0 ;; esac
    "$PYTHON_BIN" -X utf8 "$@"
}
sing-box() { :; }
systemctl() {
    echo "$*" >> "$ACTION_FILE"
    case "$1" in
        is-active) return 0 ;;
        restart) return 1 ;;
        show) echo "$RESULT" ;;
        reset-failed) [[ "$RESULT" == start-limit-hit ]] ;;
        start) [[ $(cat "$WARP_LIST") == previous.example ]] ;;
        *) return 1 ;;
    esac
}
if warp_edit_domains add next.example 2>&1; then exit 9; fi
[[ $(cat "$WARP_LIST") == previous.example ]]
""")
                actions = self.actions().splitlines()
                self.assertEqual(actions.count("restart buds-warp-split.service"), 2)
                expected = int(result == "start-limit-hit")
                self.assertEqual(actions.count("reset-failed buds-warp-split.service"), expected)
                self.assertEqual(actions.count("start buds-warp-split.service"), expected)
                self.assertIn("已恢复原清单和服务" if expected else "恢复失败", output)

    def test_warp_enable_failure_rollback_and_repeat_enable(self):
        # Use a harmless character device for the TUN presence check.
        self.sources["buds"] = self.sources["buds"].replace("/dev/net/tun", "/dev/null")
        python = shlex.quote(Path(sys.executable).as_posix())
        self.shell(f'python3() {{ {python} -X utf8 "$@"; }}\n' + """
mkdir -p "$SANDBOX/bin" "$SANDBOX/run/systemd/system" "$SANDBOX/etc/systemd/system"
printf 'nameserver 127.0.0.53\n' > "$SANDBOX/etc/resolv.conf"
cat > "$SANDBOX/bin/sing-box" <<'SB'
#!/usr/bin/env bash
case "$1" in
    version) echo 'sing-box version 1.13.0' ;;
    check) test -s "$3" ;;
    *) exit 1 ;;
esac
SB
chmod +x "$SANDBOX/bin/sing-box"
export PATH="$SANDBOX/bin:$PATH"
warp_exec_safe() { :; }
profile_path="$SANDBOX/wg.conf"
printf '%s\n' '[Interface]' 'Address=172.16.0.2/32' 'PrivateKey=fixture' '[Peer]' \\
    'PublicKey=fixture' 'Endpoint=Peer.Example.NET:2408' 'AllowedIPs=0.0.0.0/0' > "$profile_path"
unit_path="$SANDBOX/etc/systemd/system/$WARP_UNIT"
resolvectl() { :; }
ip() { :; }
flock() { :; }
systemctl() {
    echo "$*" >> "$ACTION_FILE"
    case "$1" in
        is-active) [[ "${!#}" == systemd-resolved || -f "$SANDBOX/active" ]] ;;
        show) echo not-found ;;
        enable) ln "$2" "$unit_path" ;;
        start|restart)
            (cd "$WARP_DIR" && python3 policy.py render base.json ../warp-domains .) || return 1
            if [[ -e "$SANDBOX/fail-once" ]]; then rm "$SANDBOX/fail-once"; return 1; fi
            touch "$SANDBOX/active" ;;
        stop) rm -f "$SANDBOX/active" ;;
        disable) rm "$unit_path" ;;
        daemon-reload) : ;;
        *) return 1 ;;
    esac
}
warp_verify() { return "$verify_rc"; }
warp_trace() { :; }
warp_tunnel_probe() { :; }
verify_rc=1
if warp_manage enable "$profile_path"; then exit 9; fi
[[ ! -e "$WARP_DIR" && ! -e "$unit_path" && ! -e "$SANDBOX/active" ]]
verify_rc=0
warp_manage domains add 'Example.COM.' example.com
warp_manage domains list > "$SANDBOX/policy"
[[ $(grep -cx 'example.com' "$SANDBOX/policy") == 1 ]]
if warp_manage domains add 'https://wrong.example/path' accepted.example; then exit 9; fi
if grep -Fxq accepted.example "$WARP_LIST"; then exit 9; fi
warp_manage enable "$profile_path"
[[ -s "$WARP_DIR/config.json" && -e "$unit_path" && -e "$SANDBOX/active" ]]
if warp_manage domains add example.net; then exit 9; fi
if grep -Fxq example.net "$WARP_LIST"; then exit 9; fi
warp_domain_selected child.example.com
if warp_domain_selected badexample.com; then exit 9; fi
warp_manage domains replace example.com new.example
warp_domain_selected new.example
if warp_domain_selected example.com; then exit 9; fi
touch "$SANDBOX/fail-once"
if warp_manage domains remove new.example; then exit 9; fi
warp_domain_selected new.example
grep -Fxq new.example "$WARP_LIST"
warp_manage domains remove new.example
if warp_domain_selected new.example; then exit 9; fi
printf '%s\n' '# Custom' 'chatgpt.com' > "$SANDBOX/list.txt"
warp_manage domains import "$SANDBOX/list.txt"
[[ $(cat "$WARP_DIR/domains") == chatgpt.com ]]
: > "$SANDBOX/list.txt"
warp_manage domains import "$SANDBOX/list.txt"
[[ ! -s "$WARP_DIR/domains" ]]
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["route"]["rules"] == [{"action":"reject"}] and not c["dns"]["rules"]' "$WARP_DIR/config.json"
warp_manage domains add only.example
warp_manage enable "$profile_path"
warp_manage disable
warp_manage disable
[[ ! -e "$WARP_DIR" && ! -e "$unit_path" && ! -e "$SANDBOX/active" && -s "$profile_path" ]]
[[ $(warp_manage domains list) == only.example ]]
warp_manage domains reset
grep -Fxq google.com "$WARP_LIST"
if grep -Eq 'only.example|openai.com|chatgpt.com|anthropic.com' "$WARP_LIST"; then exit 9; fi
""", timeout=45)
        self.assertEqual(self.actions().splitlines().count("start buds-warp-split.service"), 2)
        self.assertEqual(self.actions().count("stop buds-warp-split.service"), 2)

    def journal(self, contents):
        (self.config / ".firewall_rule").write_text(contents, encoding="utf-8", newline="\n")

    def certificates(self):
        def openssl(*args):
            subprocess.run([OPENSSL, *args], check=True, capture_output=True)
        for filename, subject in (("server", "node.example.com"), ("ca", "Test CA")):
            openssl("req", "-new", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-days", "1", "-subj", "/CN=" + subject,
                    "-keyout", str(self.config / (filename + ".key")),
                    "-out", str(self.config / (filename + ".crt")))
        openssl("req", "-new", "-key", str(self.config / "server.key"), "-subj", "/CN=node.example.com",
                "-out", str(self.directory / "node.csr"))
        openssl("x509", "-req", "-in", str(self.directory / "node.csr"), "-days", "1",
                "-CA", str(self.config / "ca.crt"), "-CAkey", str(self.config / "ca.key"),
                "-set_serial", "2", "-out", str(self.directory / "signed.crt"))

    def node_config(self, public="19957", local="24443"):
        (self.config / "config.yaml").write_text(
            f'listen: :{local}\nauth:\n  password: "test-password"\n'
            'obfs:\n  type: salamander\n  salamander:\n    password: "test-obfs"\n', encoding="utf-8")
        (self.config / "client.yaml").write_text(
            f'server: node.example.com:{public}\ntls:\n  sni: node.example.com\n  insecure: false\n', encoding="utf-8")

    def test_real_certificates_and_export_consistency(self):
        self.certificates()
        self.node_config()
        for source in ("buds", "install.sh"):
            self.shell("is_cert_self_signed\n", source)
        output = self.shell("link\nclient\n")
        self.assertIn("node.example.com:19957?sni=", output)
        self.assertIn("pinSHA256=", output)
        self.assertRegex(output, r":19957/\?sni=node\.example\.com&pinSHA256=[0-9a-f]{64}&insecure=1")
        self.assertNotIn("allowInsecure", output)
        self.assertIn("insecure: true", output)
        shutil.copyfile(self.directory / "signed.crt", self.config / "server.crt")
        for source in ("buds", "install.sh"):
            self.shell("if is_cert_self_signed; then exit 9; fi\n", source)
        output = self.shell("link\nclient\n")
        self.assertNotIn("allowInsecure", output)
        self.assertNotIn("insecure=", output)
        self.assertIn("insecure: false", output)
        self.assertNotIn("insecure=1", output)

    def test_installer_yaml_uses_same_cert_predicate(self):
        def predicate(path):
            text = (ROOT / path).read_text(encoding="utf-8")
            return re.search(r"is_cert_self_signed\(\) \{.*?\n\}", text, re.S).group()
        self.assertEqual(predicate("buds"), predicate("install.sh"))
        self.certificates()
        # Stop setup_cli after YAML generation, before deploying the global CLI.
        self.sources["install.sh"] = self.sources["install.sh"].split("    # 生成极客优雅的全局管理命令")[0] + "\n}\n"
        self.shell("DOMAIN=node.example.com; CLIENT_PORT_STR=19957; AUTH_PASSWORD=pass; OBFS_PASSWORD=obfs\nsetup_cli\n", "install.sh")
        self.assertIn("insecure: true", (self.config / "client.yaml").read_text(encoding="utf-8"))
        self.assertEqual((self.config / ".public_port").read_text(encoding="utf-8").strip(), "19957")

    def test_invalid_certificate_does_not_disable_validation(self):
        (self.config / "server.crt").write_text("invalid certificate")
        self.shell("if is_cert_self_signed; then exit 9; fi\n", "install.sh")

    def test_installer_uses_embedded_cli_instead_of_a_sibling_file(self):
        self.shell("""
mkdir -p "$SANDBOX/usr/local/bin"
cd "$SANDBOX"
printf 'unsigned sibling\n' > buds
DOMAIN=node.example.com; CLIENT_PORT_STR=19957; AUTH_PASSWORD=pass; OBFS_PASSWORD=obfs
setup_cli
""", "install.sh")
        installed_cli = (self.directory / "usr/local/bin/buds").read_text(encoding="utf-8")
        version_line = re.search(r'^SCRIPT_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$', self.sources["install.sh"], re.M)
        self.assertIsNotNone(version_line)
        self.assertIn(version_line.group(), installed_cli.splitlines())
        self.assertNotIn("unsigned sibling", installed_cli)

    def test_init_detection_requires_commands_and_runtime(self):
        for source in ("buds", "install.sh"):
            self.shell("""
mkdir -p "$SANDBOX/etc/init.d" "$SANDBOX/run/systemd/system"
command() { if [[ "$1" == -v && "$2" =~ ^(systemctl|rc-service|rc-update|openrc-run)$ ]]; then return 1; fi; builtin command "$@"; }
if has_systemd || has_openrc; then exit 9; fi
""", source)
        target = (self.directory / "run/systemd").resolve()
        self.assertTrue(target.is_relative_to(self.directory.resolve()))
        shutil.rmtree(target)
        self.shell("detect_init_system\n[[ \"$INIT_SYSTEM\" == other ]]\n", "install.sh")
        self.shell("""
mkdir -p "$SANDBOX/run/openrc"; touch "$SANDBOX/run/openrc/softlevel"
has_openrc
detect_init_system
[[ "$INIT_SYSTEM" == openrc ]]
""", "install.sh")
        self.shell('mkdir -p "$SANDBOX/run/systemd/system"\nhas_systemd\ndetect_init_system\n[[ "$INIT_SYSTEM" == systemd ]]\n', "install.sh")

    def test_openrc_cli_controls(self):
        self.shell('mkdir -p "$SANDBOX/run/openrc"; touch "$SANDBOX/run/openrc/softlevel"\nstart\nstop\nrestart\n')
        self.assertEqual(self.actions().splitlines(), [
            "rc-service hysteria-server start", "rc-service hysteria-server stop", "rc-service hysteria-server restart"])

    def test_systemd_direct_download_gets_complete_service(self):
        self.shell("INIT_SYSTEM=systemd\nconfigure_service\n", "install.sh")
        unit = (self.directory / "etc/systemd/system/hysteria-server.service").read_text(encoding="utf-8")
        self.assertIn("ExecStart=", unit)
        self.assertIn("hysteria server --config", unit)
        self.assertIn("WantedBy=multi-user.target", unit)
        self.assertIn("AmbientCapabilities=CAP_NET_BIND_SERVICE", unit)
        self.assertNotIn("CAP_NET_ADMIN", unit)
        self.assertTrue((self.directory / "etc/systemd/system/hysteria-server.service.d/override.conf").exists())
        self.assertIn("systemctl daemon-reload", self.actions())

    def test_port_hopping_retains_required_net_admin_capability(self):
        self.shell("INIT_SYSTEM=systemd; IS_PORT_HOPPING=true\nconfigure_service\n", "install.sh")
        unit = (self.directory / "etc/systemd/system/hysteria-server.service").read_text(encoding="utf-8")
        self.assertIn("CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN", unit)
        self.assertIn("AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN", unit)
        self.assertNotIn("CAP_NET_RAW", unit)
        self.assertNotIn("setcap", self.actions())
        self.shell("""
INIT_SYSTEM=openrc; IS_PORT_HOPPING=true
mkdir -p "$SANDBOX/etc/init.d"
id() { return 0; }
service_group_exists() { return 0; }
supervise-daemon() { return 1; }
configure_service
""", "install.sh")
        unit = (self.directory / "etc/init.d/hysteria-server").read_text(encoding="utf-8")
        self.assertIn('command_user="root:root"', unit)
        self.assertNotIn("capabilities=", unit)

    def test_openrc_capability_is_set_on_service(self):
        self.shell("""
id() { return 0; }
service_group_exists() { return 0; }
supervise-daemon() {
    [[ "$RC_SVCNAME" == hysteria-server && "$*" == 'hysteria-server --help' ]] || return 1
    printf '%s\\n' '--capabilities'
}
mkdir -p "$SANDBOX/etc/init.d" "$SANDBOX/usr/local/bin"
touch "$SANDBOX/usr/local/bin/hysteria"
INIT_SYSTEM=openrc; IS_PORT_HOPPING=true
configure_service
""", "install.sh")
        unit = (self.directory / "etc/init.d/hysteria-server").read_text(encoding="utf-8")
        self.assertIn('command_user="hysteria:hysteria"', unit)
        self.assertIn('capabilities="^cap_net_admin"', unit)
        self.assertNotIn("cap_net_raw", unit)
        self.assertNotIn("setcap", self.actions())

    def test_openrc_single_port_omits_capability_option(self):
        self.shell("""
id() { return 0; }
service_group_exists() { return 0; }
mkdir -p "$SANDBOX/etc/init.d"
INIT_SYSTEM=openrc; IS_PORT_HOPPING=false
configure_service
""", "install.sh")
        unit = (self.directory / "etc/init.d/hysteria-server").read_text(encoding="utf-8")
        self.assertIn('command_user="hysteria:hysteria"', unit)
        self.assertNotIn("capabilities=", unit)

    def test_openrc_missing_user_uses_root_fallback(self):
        self.shell('id() { return 1; }\nmkdir -p "$SANDBOX/etc/init.d" "$SANDBOX/usr/local/bin"; touch "$SANDBOX/usr/local/bin/hysteria"\nINIT_SYSTEM=openrc; IS_PORT_HOPPING=true\nconfigure_service\n', "install.sh")
        unit = (self.directory / "etc/init.d/hysteria-server").read_text(encoding="utf-8")
        self.assertIn('command_user="root:root"', unit)
        self.assertNotIn("cap_net_admin", unit)

    def test_busybox_creates_dedicated_service_group_before_user(self):
        self.shell("""
service_group_exists() { return 1; }
id() { return 1; }
command() {
    if [[ "$1" == -v && "$2" =~ ^(groupadd|useradd)$ ]]; then return 1; fi
    builtin command "$@"
}
addgroup() { echo "addgroup $*" >> "$ACTION_FILE"; }
adduser() { echo "adduser $*" >> "$ACTION_FILE"; }
ensure_service_account
""", "install.sh")
        self.assertEqual(self.actions().splitlines(), [
            "addgroup -S hysteria",
            "adduser -S -D -H -G hysteria -s /sbin/nologin hysteria",
        ])

    def test_start_service_reloads_new_configuration(self):
        self.shell("INIT_SYSTEM=systemd\nstart_service\n", "install.sh")
        actions = self.actions()
        self.assertIn("systemctl enable hysteria-server", actions)
        self.assertIn("systemctl restart hysteria-server", actions)

    def test_no_init_container_gets_lightweight_runner(self):
        self.shell('mkdir -p "$SANDBOX/usr/local/bin"\nINIT_SYSTEM=other\nconfigure_service\n', "install.sh")
        self.assertTrue((self.directory / "usr/local/bin/hysteria-service").exists())
        self.assertNotIn("rc-service", self.actions())

    def test_nat_public_port_collection_and_defaults(self):
        common = """
validate_domain() { :; }
generate_random_port() { echo 24443; }
generate_random_string() { echo random; }
check_port_available() { return 0; }
IS_NAT=true; IS_CONTAINER=true
"""
        self.shell(common + """collect_parameters <<'INPUT'
node.example.com
24443
bad
443
INPUT
[[ "$LISTEN_STR" == :24443 && "$CLIENT_PORT_STR" == 443 && "$UFW_PORT_RULE" == 24443/udp ]]
""", "install.sh")
        self.shell(common + """collect_parameters <<'INPUT'
node.example.com
24443
bad

INPUT
[[ "$CLIENT_PORT_STR" == 24443 ]]
""", "install.sh")

    def test_nat_range_export_and_missing_client_recovery(self):
        self.certificates()
        self.node_config(public="30000-30009", local="20000-20009")
        output = self.shell("link\n")
        self.assertIn("node.example.com:30000?sni=", output)
        self.assertIn("&mport=30000-30009", output)
        (self.config / ".public_port").write_text("30000-30009\n")
        (self.config / "client.yaml").unlink()
        output = self.shell("client\n")
        self.assertIn("server: node.example.com:30000-30009", output)
        self.assertIn("insecure: true", output)

    def test_port_boundaries(self):
        self.shell("""
[[ "$(normalize_ports 00080)" == 80 ]]
[[ "$(normalize_ports 20000:20009)" == 20000-20009 ]]
[[ "$(normalize_ports 1-65535)" == 1-65535 ]]
for input in 0 65536 18446744073709553664 20000-20000 30000-20000 abc 000080; do
  if normalize_ports "$input"; then exit 9; fi
done
if normalize_ports 443 1024; then exit 9; fi
""", "install.sh")

    def test_repeat_install_opens_menu_without_overwriting(self):
        self.node_config()
        original = (self.config / "config.yaml").read_bytes()
        cli = self.directory / "usr/local/bin/buds"
        cli.parent.mkdir(parents=True)
        cli.write_text('#!/usr/bin/env bash\nprintf "MANAGEMENT:%s\\n" "$1"\n')
        cli.chmod(0o755)
        output = self.shell("check_root() { :; }\ndetect_virtualization() { exit 9; }\nmain\n", "install.sh")
        self.assertIn("MANAGEMENT:hy2", output)
        self.assertEqual(original, (self.config / "config.yaml").read_bytes())

    def test_existing_config_without_cli_is_protected(self):
        self.node_config()
        original = (self.config / "config.yaml").read_bytes()
        self.shell("check_root() { :; }\nmain\n", "install.sh", expected=1)
        self.assertEqual(original, (self.config / "config.yaml").read_bytes())

    def test_certificate_failure_preserves_other_services(self):
        for nginx_running in (True, False):
            self.shell(f"""
IS_NAT=false; IS_CONTAINER=false; HAVE_CERTBOT=true; DOMAIN=node.example.com
is_nginx_running() {{ return {0 if nginx_running else 1}; }}
is_port_80_listening() {{ return 0; }}
find_nginx_webroot() {{ echo "$SANDBOX/webroot"; }}
certbot() {{ echo "certbot $*" >> "$ACTION_FILE"; return 1; }}
generate_self_signed_cert() {{ echo self-signed >> "$ACTION_FILE"; }}
setup_certificates <<<'1'
""", "install.sh")
            actions = self.actions()
            self.assertIn("self-signed", actions)
            for forbidden in ("stop", "pkill", "killall", "--standalone", "systemctl", "rc-service"):
                self.assertNotIn(forbidden, actions)
            if nginx_running:
                self.assertIn("--nginx", actions)
                self.assertIn("--webroot", actions)

    def test_standalone_only_with_free_port(self):
        self.shell("""
IS_NAT=false; IS_CONTAINER=false; HAVE_CERTBOT=true; DOMAIN=node.example.com
is_nginx_running() { return 1; }; is_port_80_listening() { return 1; }
certbot() { echo "certbot $*" >> "$ACTION_FILE"; return 1; }
generate_self_signed_cert() { echo self-signed >> "$ACTION_FILE"; }
setup_certificates <<<'1'
""", "install.sh")
        self.assertIn("--standalone", self.actions())
        self.assertIn("self-signed", self.actions())

    def test_ufw_preserves_existing_and_records_only_added_rule(self):
        self.shell("""
ufw() { [[ "$1" == status ]] && { printf 'Status: active\\n24443/udp ALLOW Anywhere # existing\\n'; return 0; }; echo "ufw $*" >> "$ACTION_FILE"; }
add_ufw_rule 24443/udp
add_ufw_rule 80/tcp
""", "install.sh")
        self.assertEqual(self.actions().strip(), "ufw allow in proto tcp from 0.0.0.0/0 to any port 80 comment buds-hy2")
        self.assertEqual((self.config / ".firewall_rule").read_text(encoding="utf-8"), "ufw|4|runtime|80/tcp\n")

    def test_ufw_cleanup_deletes_only_owned_numbered_rules(self):
        self.journal("ufw|-|runtime|24443/udp\n")
        self.shell("""
ufw() {
 if [[ "$1" == status ]]; then
   printf 'Status: active\\n[ 1] 24443/udp ALLOW IN Anywhere # existing\\n[ 2] 24443/udp ALLOW IN Anywhere # buds-hy2\\n[ 3] 24443/udp (v6) ALLOW IN Anywhere (v6) # buds-hy2\\n'
 else echo "ufw $*" >> "$ACTION_FILE"; fi
}
cleanup_firewall
""")
        self.assertEqual(self.actions().splitlines(), ["ufw --force delete 3", "ufw --force delete 2"])
        self.assertFalse((self.config / ".firewall_rule").exists())

    def test_disabled_ufw_checks_saved_comment(self):
        self.journal("ufw|-|runtime|24443/udp\n")
        self.shell("""
ufw() {
 if [[ "$1" == status ]]; then echo 'Status: inactive'
 elif [[ "$1" == show ]]; then echo "ufw allow 24443/udp comment 'buds-hy2'"
 else echo "ufw $*" >> "$ACTION_FILE"; fi
}
cleanup_firewall
""")
        self.assertEqual(self.actions().strip(), "ufw --force delete allow 24443/udp comment buds-hy2")

    def test_firewall_cleanup_failure_has_no_plain_fallback(self):
        self.journal("iptables|INPUT|runtime|24443/udp\n")
        self.shell("""
iptables() { echo "iptables $*" >> "$ACTION_FILE"; [[ "$1" == -C ]]; }
cleanup_firewall
""", expected=1)
        self.assertTrue((self.config / ".firewall_rule").exists())
        self.assertEqual(len(self.actions().splitlines()), 2)
        self.assertTrue(all("--comment buds-hy2" in line for line in self.actions().splitlines()))

    def test_disabled_ufw_mixed_ownership_keeps_record(self):
        self.journal("ufw|-|runtime|24443/udp\n")
        self.shell("""
ufw() {
 if [[ "$1" == status ]]; then echo 'Status: inactive'
 elif [[ "$1" == show ]]; then
   echo "ufw allow 24443/udp comment 'buds-hy2'"
   echo "ufw allow 24443/udp comment 'existing'"
 else echo "ufw $*" >> "$ACTION_FILE"; fi
}
cleanup_firewall
""", expected=1)
        self.assertEqual(self.actions(), "")
        self.assertTrue((self.config / ".firewall_rule").exists())

    def test_iptables_saved_cleanup_is_retried_even_after_rule_disappears(self):
        self.journal("iptables|INPUT|runtime|24443/udp\n")
        save = self.directory / "etc/init.d/iptables"
        save.parent.mkdir(parents=True)
        save.write_text('#!/usr/bin/env bash\ntouch ' + shlex.quote(self.sandbox + '/saved') + '\n', newline="\n")
        save.chmod(0o755)
        self.shell('iptables() { return 1; }\ncleanup_firewall\n')
        self.assertTrue((self.directory / "saved").exists())
        self.assertFalse((self.config / ".firewall_rule").exists())

    def test_successful_uninstall_removes_node_metadata_and_reinstall_is_fresh(self):
        self.node_config()
        (self.config / ".public_port").write_text("19957\n")
        binary_dir = self.directory / "usr/local/bin"
        binary_dir.mkdir(parents=True)
        for name in ("buds", "hy2", "hysteria"):
            (binary_dir / name).write_text("old-install")
        runner = binary_dir / "hysteria-service"
        runner.write_text('#!/usr/bin/env bash\n[[ "$1" == stop ]]\n', encoding="utf-8", newline="\n")
        runner.chmod(0o755)
        self.shell("uninstall <<<'y'\n")
        self.assertFalse(self.config.exists())
        self.assertTrue(all(not (binary_dir / name).exists() for name in ("buds", "hy2", "hysteria", "hysteria-service")))
        self.shell("""
check_root() { :; }
detect_virtualization() { :; }; detect_init_system() { :; }
install_dependencies() { :; }; setup_certificates() { :; }
install_official_core() { :; }; tune_kernel_network() { :; }
configure_service() { :; }; configure_firewall() { :; }; start_service() { :; }
setup_cli() { :; }; display_summary() { :; }
collect_parameters() { DOMAIN=new.example.com; AUTH_PASSWORD=new-password; }
generate_server_config() { mkdir -p "$CONFIG_DIR"; printf '%s\\n' "$DOMAIN" "$AUTH_PASSWORD" > "$CONFIG_FILE"; }
main
""", "install.sh")
        self.assertEqual((self.config / "config.yaml").read_text(encoding="utf-8"), "new.example.com\nnew-password\n")

    def test_firewalld_runtime_and_permanent_ownership(self):
        self.shell("""
command() { if [[ "$1" == -v && "$2" == ufw ]]; then return 1; fi; builtin command "$@"; }
firewall-cmd() {
 case "$*" in
  --state) return 0;;
  --get-default-zone) echo public;;
  *--query-port=*) [[ "$*" != *--permanent* ]];;
  *) echo "firewall-cmd $*" >> "$ACTION_FILE";;
 esac
}
UFW_PORT_RULE=24443/udp
configure_firewall
""", "install.sh")
        self.assertEqual((self.config / ".firewall_rule").read_text(encoding="utf-8"), "firewalld|public|permanent|24443/udp\n")
        self.assertNotIn("--reload", self.actions())
        self.shell('firewall-cmd() { echo "firewall-cmd $*" >> "$ACTION_FILE"; }\ncleanup_firewall\n')
        self.assertIn("--permanent --remove-port=24443/udp", self.actions())
        self.assertNotIn("--reload", self.actions())

    def test_iptables_existing_or_failed_rule_is_not_claimed(self):
        for existing in (True, False):
            self.shell(f"""
command() {{ if [[ "$1" == -v && "$2" =~ ^(ufw|firewall-cmd)$ ]]; then return 1; fi; builtin command "$@"; }}
iptables() {{ echo "iptables $*" >> "$ACTION_FILE"; return {0 if existing else 1}; }}
UFW_PORT_RULE=24443/udp
configure_firewall
""", "install.sh")
            self.assertFalse((self.config / ".firewall_rule").exists())
            if not existing:
                insertions = [line for line in self.actions().splitlines() if "-I " in line]
                self.assertEqual(len(insertions), 1)
                self.assertIn("--comment buds-hy2", insertions[0])



    def test_dns_failure_falls_back_and_all_failed_is_explicit(self):
        script = """
PUBLIC_IP=203.0.113.1; DOMAIN=node.example.com
getent() { return 2; }
dig() { echo 203.0.113.1; }
validate_domain
echo REACHED_NEXT_STEP
"""
        output = self.shell(script, "install.sh")
        self.assertIn("REACHED_NEXT_STEP", output)
        self.assertNotIn("WARN:", output)
        output = self.shell("""
PUBLIC_IP=203.0.113.1; DOMAIN=missing.example
getent() { return 2; }; dig() { return 1; }
host() { return 1; }; nslookup() { return 1; }
validate_domain
echo REACHED_NEXT_STEP
""", "install.sh")
        self.assertIn("WARN:", output)
        self.assertIn("REACHED_NEXT_STEP", output)

    def test_nslookup_does_not_use_dns_server_address_as_domain_answer(self):
        output = self.shell("""
PUBLIC_IP=203.0.113.1; DOMAIN=missing.example
command() { if [[ "$1" == -v && "$2" =~ ^(getent|dig|host)$ ]]; then return 1; fi; builtin command "$@"; }
nslookup() { printf 'Server: 8.8.8.8\\nAddress: 8.8.8.8#53\\n'; return 1; }
validate_domain
""", "install.sh")
        self.assertIn("暂未查询到", output)
        self.assertNotIn("8.8.8.8", output)

    def test_missing_required_dependencies_fail_before_configuration(self):
        output = self.shell("""
command() { if [[ "$1" == -v ]]; then return 1; fi; builtin command "$@"; }
install_dependencies
echo SHOULD_NOT_REACH
""", "install.sh", expected=1)
        self.assertIn("缺少必需工具", output)
        self.assertNotIn("SHOULD_NOT_REACH", output)

    def test_certbot_is_optional_and_arch_does_not_refresh_or_upgrade_system(self):
        self.shell("""
command() { if [[ "$1" == -v && "$2" =~ ^(apt-get|apk|dnf|yum|certbot)$ ]]; then return 1; fi; builtin command "$@"; }
pacman() { echo "pacman $*" >> "$ACTION_FILE"; }
pgrep() { return 1; }
install_dependencies
[[ "$HAVE_CERTBOT" == false ]]
""", "install.sh")
        self.assertTrue(self.actions())
        for command in self.actions().splitlines():
            self.assertIn("pacman -S --needed --noconfirm", command)
            self.assertNotIn("-Sy", command)
            self.assertNotIn("-Su", command)
        self.assertNotIn("openssl certbot", self.actions())

    def test_ufw_restricted_source_and_outbound_rules_do_not_count_as_open(self):
        for rule in ("24443/udp ALLOW IN 192.0.2.10", "24443/udp ALLOW OUT Anywhere"):
            self.shell(f"""
ufw() {{ if [[ "$1" == status ]]; then printf 'Status: active\\n{rule}\\n'; else echo "ufw $*" >> "$ACTION_FILE"; fi; }}
add_ufw_rule 24443/udp
""", "install.sh")
            self.assertIn("from 0.0.0.0/0 to any port 24443", self.actions())

    def test_ufw_ipv4_add_does_not_overwrite_existing_ipv6_rule(self):
        config = self.directory / "etc/default/ufw"
        config.parent.mkdir(parents=True)
        config.write_text("IPV6=yes\n", newline="\n")
        self.shell("""
ufw() {
 if [[ "$1" == status ]]; then printf 'Status: active\\n24443/udp (v6) ALLOW IN Anywhere (v6) # existing\\n'
 else echo "ufw $*" >> "$ACTION_FILE"; fi
}
add_ufw_rule 24443/udp
""", "install.sh")
        self.assertIn("from 0.0.0.0/0", self.actions())
        self.assertNotIn("from ::/0", self.actions())
        self.assertEqual((self.config / ".firewall_rule").read_text(encoding="utf-8"), "ufw|4|runtime|24443/udp\n")

    def test_lightweight_failed_restart_returns_failure(self):
        output = self.shell("""
mkdir -p "$SANDBOX/usr/local/bin" "$SANDBOX/var/log"
INIT_SYSTEM=other; configure_service
pgrep() { return 1; }; nohup() { return 1; }
export -f pgrep nohup sleep
bash "$SANDBOX/usr/local/bin/hysteria-service" restart
""", "install.sh", expected=1)
        self.assertNotIn("重启完成", output)

    def test_lightweight_start_stop_restart_checks_own_process(self):
        self.shell("""
mkdir -p "$SANDBOX/usr/local/bin" "$SANDBOX/var/log"
INIT_SYSTEM=other; configure_service
pgrep() { [[ -f "$SANDBOX/running" ]]; }
nohup() { touch "$SANDBOX/running"; }
pkill() { rm -f "$SANDBOX/running"; }
sleep() { wait; }
export SANDBOX
export -f pgrep nohup pkill sleep
bash "$SANDBOX/usr/local/bin/hysteria-service" start
bash "$SANDBOX/usr/local/bin/hysteria-service" restart
bash "$SANDBOX/usr/local/bin/hysteria-service" stop
[[ ! -f "$SANDBOX/running" ]]
""", "install.sh")

    def test_uninstall_removes_only_own_startup_line(self):
        self.node_config()
        startup = self.directory / "etc/rc.local"
        startup.write_text(
            "#!/bin/sh\necho keep-this\n" + self.sandbox + "/usr/local/bin/hysteria-service start\nexit 0\n",
            newline="\n",
        )
        self.shell("uninstall <<<'y'\n")
        self.assertEqual(startup.read_text(encoding="utf-8"), "#!/bin/sh\necho keep-this\nexit 0\n")

    def test_self_signed_pin_matches_der_sha256_and_is_exported(self):
        import hashlib
        self.certificates()
        self.node_config()
        der = subprocess.check_output(
            [OPENSSL, "x509", "-in", str(self.config / "server.crt"), "-outform", "DER"]
        )
        expected = hashlib.sha256(der).hexdigest()
        for source in ("buds", "install.sh"):
            self.assertEqual(self.shell("get_cert_pin\n", source).strip(), expected)
        output = self.shell("link\nclient\nclient\n")
        self.assertIn("&pinSHA256=" + expected, output)
        yaml = (self.config / "client.yaml").read_text(encoding="utf-8")
        self.assertEqual(yaml.count("pinSHA256:"), 1)
        self.assertIn("pinSHA256: " + expected, yaml)
        shutil.copyfile(self.directory / "signed.crt", self.config / "server.crt")
        output = self.shell("link\nclient\n")
        self.assertNotIn("pinSHA256", output)
        self.assertIn("insecure: false", output)

    def test_split_legacy_client_recovers_nat_port_and_credentials_without_losing_options(self):
        self.node_config()
        path = self.config / "client.yaml"
        path.write_text('server: node.example.com\nnode.example.com:19957-19959\nauth: ""\n'
                        'tls:\n  sni: node.example.com\nnode.example.com\n  insecure: false\n'
                        'obfs:\n  type: salamander\n  salamander:\n    password: ""\n'
                        'socks5:\n  listen: 127.0.0.1:1088\n', encoding="utf-8")
        self.assertEqual(self.shell("get_public_ports\n").strip(), "19957-19959")
        self.shell("client >/dev/null\n")
        recovered = path.read_text(encoding="utf-8")
        self.assertIn("server: node.example.com:19957-19959\n", recovered)
        self.assertNotIn("\nnode.example.com", recovered)
        self.assertIn('auth: "test-password"', recovered)
        self.assertIn('password: "test-obfs"', recovered)
        self.assertIn("127.0.0.1:1088", recovered)
        self.shell("client >/dev/null\n")
        self.assertEqual(path.read_text(encoding="utf-8"), recovered)

    def test_pin_is_added_when_existing_yaml_has_no_tls_block(self):
        self.certificates()
        self.node_config()
        (self.config / "client.yaml").write_text(
            "server: node.example.com:19957\nauth: keep-me\n", newline="\n"
        )
        self.shell("client\n")
        result = (self.config / "client.yaml").read_text(encoding="utf-8")
        self.assertIn("auth: keep-me", result)
        self.assertIn("pinSHA256:", result)
        self.assertIn("insecure: true", result)

    def test_sing_box_export_is_valid_and_requires_self_signed_pin(self):
        self.certificates()
        self.node_config(public="19957-19959")
        output = self.shell("link\nclient\n")
        self.assertRegex(output, r":19957-19959/\?sni=[^&]+&pinSHA256=[0-9a-f]{64}&insecure=1")
        outbound = json.loads(re.search(r"(?ms)^\{\n.*?^\}", output).group())
        self.assertEqual(outbound["server_ports"], ["19957:19959"])
        self.assertNotIn("server_port", outbound)
        self.assertFalse(outbound["tls"]["insecure"])
        self.assertRegex(outbound["tls"]["certificate_public_key_sha256"][0], r"^[A-Za-z0-9+/]{43}=$")
        output = self.shell("get_spki_pin() { return 1; }\nclient\n")
        self.assertIn("已跳过 sing-box 配置", output)
        self.assertNotIn('"type": "hysteria2"', output)

    def test_pin_failure_refuses_unverified_self_signed_export(self):
        self.certificates()
        self.node_config()
        for action in ("link", "client"):
            output = self.shell("get_cert_pin() { return 1; }\n" + action + "\n", expected=1)
            self.assertNotIn("hysteria2://", output)

    def download_fixture(self, digest=None, valid_version=True, valid_binary=True):
        import hashlib
        payload = "test-core-fixture"
        digest = digest or hashlib.sha256(payload.encode()).hexdigest()
        version = "app/v2.13.0" if valid_version else "unexpected"
        validation = 0 if valid_binary else 1
        return f"""
EXPECTED_DIGEST={shlex.quote(digest)}
PAYLOAD={shlex.quote(payload)}
uname() {{ echo x86_64; }}
validate_core_binary() {{ echo VALIDATE >> "$ACTION_FILE"; return {validation}; }}
curl() {{
 local url="" output=""
 while (( $# )); do
  case "$1" in
   -o) shift; output="$1";;
   https://*) url="$1";;
  esac
  shift
 done
 echo "curl $url" >> "$ACTION_FILE"
 case "$url" in
  */releases/latest) printf 'HTTP/2 302\\nlocation: https://github.com/HyNetworks/hysteria/releases/tag/{version}\\n';;
  */hashes.txt) printf '%s  build/hysteria-linux-amd64\\n' "$EXPECTED_DIGEST" > "$output";;
  */hysteria-linux-amd64) printf '%s' "$PAYLOAD" > "$output";;
  *) return 1;;
 esac
}}
"""

    def test_download_hash_mismatch_preserves_old_binary_and_never_executes(self):
        binary = self.directory / "usr/local/bin/hysteria"
        binary.parent.mkdir(parents=True)
        binary.write_text("existing-core")
        self.shell(self.download_fixture(digest="0" * 64) + "install_official_core\n", "install.sh", expected=1)
        self.assertEqual(binary.read_text(encoding="utf-8"), "existing-core")
        self.assertNotIn("VALIDATE", self.actions())
        self.assertFalse(list(binary.parent.glob(".buds-hy2-download.*")))

    def test_verified_download_is_fixed_version_and_temp_is_removed(self):
        self.shell(self.download_fixture() + "install_official_core\n", "install.sh")
        binary = self.directory / "usr/local/bin/hysteria"
        self.assertEqual(binary.read_text(encoding="utf-8"), "test-core-fixture")
        self.assertIn("VALIDATE", self.actions())
        downloads = [line for line in self.actions().splitlines() if "/download/" in line]
        self.assertEqual(len(downloads), 2)
        self.assertTrue(all("/download/app/v2.13.0/" in line for line in downloads))
        self.assertFalse(list(binary.parent.glob(".buds-hy2-download.*")))

    def test_invalid_metadata_or_nonrunning_binary_cannot_replace_core(self):
        binary = self.directory / "usr/local/bin/hysteria"
        binary.parent.mkdir(parents=True)
        binary.write_text("existing-core")
        for fixture in (self.download_fixture(valid_version=False), self.download_fixture(valid_binary=False)):
            self.shell(fixture + "install_official_core\n", "install.sh", expected=1)
            self.assertEqual(binary.read_text(encoding="utf-8"), "existing-core")
            self.assertFalse(list(binary.parent.glob(".buds-hy2-download.*")))

    def test_non_elf_download_is_not_executed(self):
        payload = self.directory / "payload"
        payload.write_text('#!/usr/bin/env bash\necho EXECUTED\n', newline="\n")
        payload.chmod(0o755)
        output = self.shell('if validate_core_binary "$SANDBOX/payload"; then exit 9; fi\n', "install.sh")
        self.assertNotIn("EXECUTED", output)

    def test_existing_renewal_timer_is_enabled_without_duplicate(self):
        self.shell("""
has_systemd() { return 0; }
certbot() { :; }
systemctl() { echo "systemctl $*" >> "$ACTION_FILE"; }
configure_renewal
""", "install.sh")
        self.assertIn("enable --now certbot.timer", self.actions())
        self.assertFalse((self.directory / "etc/systemd/system/buds-hy2-renew.timer").exists())

    def test_missing_renewal_timer_gets_owned_service_and_timer(self):
        self.shell("""
mkdir -p "$SANDBOX/etc/systemd/system"
has_systemd() { return 0; }
certbot() { :; }
systemctl() { echo "systemctl $*" >> "$ACTION_FILE"; [[ "$1" != cat ]]; }
configure_renewal
""", "install.sh")
        unit = (self.directory / "etc/systemd/system/buds-hy2-renew.service").read_text(encoding="utf-8")
        self.assertIn("renew --quiet --run-deploy-hooks", unit)
        self.assertIn("enable --now buds-hy2-renew.timer", self.actions())

    def test_existing_cron_renewal_is_reused(self):
        path = self.directory / "etc/cron.d/foreign-certbot"
        path.parent.mkdir(parents=True)
        contents = "0 1 * * * root /usr/bin/certbot renew\n"
        path.write_text(contents, newline="\n")
        self.shell("""
has_systemd() { return 0; }
certbot() { :; }; systemctl() { return 1; }
ensure_cron_running() { echo CRON_READY >> "$ACTION_FILE"; }
configure_renewal
""", "install.sh")
        self.assertIn("CRON_READY", self.actions())
        self.assertEqual(path.read_text(encoding="utf-8"), contents)
        self.assertFalse((self.directory / "etc/systemd/system/buds-hy2-renew.timer").exists())

    def test_owned_cron_job_is_idempotent_and_uninstall_preserves_other_jobs(self):
        root_cron = self.directory / "root-cron"
        original = "5 1 * * * echo keep-this\n"
        root_cron.write_text(original, newline="\n")
        common = """
crontab() { if [[ "$1" == -l ]]; then cat "$SANDBOX/root-cron"; else cat > "$SANDBOX/root-cron"; fi; }
"""
        self.shell(common + """
certbot() { :; }
ensure_cron_running() { return 0; }
configure_renewal
configure_renewal
""", "install.sh")
        self.assertEqual(root_cron.read_text(encoding="utf-8").count("# buds-hy2-renew"), 1)
        self.shell(common + "cleanup_renewal\n")
        self.assertEqual(root_cron.read_text(encoding="utf-8"), original)

    def test_crontab_read_failure_never_overwrites_other_jobs(self):
        self.shell("""
crontab() { if [[ "$1" == -l ]]; then echo 'permission denied' >&2; return 1; else echo OVERWRITE >> "$ACTION_FILE"; fi; }
cleanup_renewal
""", expected=1)
        self.assertNotIn("OVERWRITE", self.actions())

    def test_version_comparison_logic(self):
        output = self.shell("""
is_version_newer "1.2.1" "1.2.0" && echo "PASS1"
is_version_newer "1.2.0" "1.2.0" || echo "PASS2"
is_version_newer "1.1.9" "1.2.0" || echo "PASS3"
is_version_newer "1.10.0" "1.9.0" && echo "PASS4"
is_version_newer "2.0.0" "1.9.9" && echo "PASS5"
is_version_newer "v1.3.0" "1.2.0" && echo "PASS6"
is_version_newer "" "1.2.0" || echo "PASS7"
""")
        self.assertEqual(output.strip().splitlines(), [f"PASS{i}" for i in range(1, 8)])

    def test_remote_version_uses_only_fresh_cache(self):
        out = self.shell("""
printf '%s:2.0.0\n' "$(date +%s)" > "$VERSION_CACHE_FILE"
curl() { echo CURL_CALLED >> "$ACTION_FILE"; return 1; }
check_remote_version
""")
        self.assertEqual(out.strip(), "2.0.0")
        self.assertNotIn("CURL_CALLED", self.actions())
        key = self.directory / "etc/buds-hy2/update.pub"
        key.parent.mkdir()
        key.write_text("nonempty fixture")

        out = self.shell("""
printf '%s:2.0.0\n' "$(( $(date +%s) + 3600 ))" > "$VERSION_CACHE_FILE"
curl() { echo CURL_CALLED >> "$ACTION_FILE"; return 1; }
check_remote_version
""", expected=1)
        self.assertEqual(out, "")
        self.assertIn("CURL_CALLED", self.actions())

    def test_update_verifies_repository_manifest_and_script_before_replacing_script(self):
        target_cli = self.directory / "usr/local/bin/buds"
        target_cli.parent.mkdir(parents=True)
        initial = '#!/usr/bin/env bash\nSCRIPT_VERSION="1.3.1"\n'
        target_cli.write_text(initial, encoding="utf-8", newline="\n")
        public_key = self.directory / "etc/buds-hy2/update.pub"
        public_key.parent.mkdir(parents=True)
        release_script = self.directory / "release-buds"
        private_key = self.directory / "fixture.key"
        signature = self.directory / "release-buds.sig"
        manifest = self.directory / "release-buds.version"
        manifest_sig = self.directory / "release-buds.version.sig"

        def openssl(*args):
            subprocess.run([OPENSSL, *map(str, args)], check=True, capture_output=True)

        def sign_script(contents):
            release_script.write_text(contents, encoding="utf-8", newline="\n")
            openssl("dgst", "-sha256", "-sign", private_key, "-out", signature, release_script)

        openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", private_key)
        openssl("pkey", "-in", private_key, "-pubout", "-out", public_key)
        manifest.write_text("1.4.0\n", encoding="utf-8", newline="\n")
        openssl("dgst", "-sha256", "-sign", private_key, "-out", manifest_sig, manifest)
        mock_download = """
SCRIPT_VERSION=1.3.1
flock() { [[ "$1" == -x && "$2" =~ ^[0-9]+$ ]]; }
curl() {
    case " $* " in
        *'/updates/buds.version '*|*'/updates/buds.version?check='*) cp "$SANDBOX/release-buds.version" "${!#}" ;;
        *'/updates/buds.version.sig '*|*'/updates/buds.version.sig?check='*) cp "$SANDBOX/release-buds.version.sig" "${!#}" ;;
        *'/updates/releases/1.4.0/buds '*) cp "$SANDBOX/release-buds" "${!#}" ;;
        *'/updates/releases/1.4.0/buds.sig '*) cp "$SANDBOX/release-buds.sig" "${!#}" ;;
        *) return 1 ;;
    esac
}
update_script 2>&1
"""
        valid = '#!/usr/bin/env bash\nSCRIPT_VERSION="1.4.0"\necho updated\n'
        manifest.write_text("9.9.9\n", encoding="utf-8", newline="\n")
        out = self.shell(mock_download, expected=1)
        self.assertIn("仓库更新版本验签失败", out)
        self.assertEqual(target_cli.read_text(encoding="utf-8"), initial)
        manifest.write_text("1.4.0\n", encoding="utf-8", newline="\n")
        mixed_cache = mock_download.replace('case " $* " in', '''case " $* " in
        *'/updates/buds.version.sig '*) printf stale > "${!#}" ;;
        *'/updates/buds.version?check='*) echo retry >> "$ACTION_FILE"; cp "$SANDBOX/release-buds.version" "${!#}" ;;''')
        self.assertEqual(self.shell(mixed_cache.replace("update_script 2>&1", "fetch_repo_version")).strip(), "1.4.0")
        self.assertEqual(self.actions(), "retry\n")
        sign_script(valid)
        release_script.write_text(valid + "echo changed\n", encoding="utf-8", newline="\n")
        out = self.shell(mock_download, expected=1)
        self.assertIn("发布签名验证失败", out)
        self.assertEqual(target_cli.read_text(encoding="utf-8"), initial)
        self.assertEqual(list(target_cli.parent.glob(".buds_update.*")), [])

        sign_script(valid.replace("1.4.0", "9.9.9"))
        out = self.shell(mock_download, expected=1)
        self.assertIn("版本不匹配", out)
        self.assertEqual(target_cli.read_text(encoding="utf-8"), initial)

        sign_script(valid + "if then invalid syntax\n")
        out = self.shell(mock_download, expected=1)
        self.assertIn("语法校验未通过", out)
        self.assertEqual(target_cli.read_text(encoding="utf-8"), initial)

        sign_script(valid)
        out = self.shell(mock_download)
        self.assertIn("脚本已成功更新至 v1.4.0", out)
        self.assertEqual(target_cli.read_text(encoding="utf-8"), valid)
        self.assertEqual(list(target_cli.parent.glob(".buds_update.*")), [])

        out = self.shell(mock_download)
        self.assertIn("已安装 v1.4.0", out)

    def test_update_requires_provisioned_key(self):
        out = self.shell('SCRIPT_VERSION=1.3.1\ncurl() { echo "1.4.0"; }\nupdate_script 2>&1\n', expected=1)
        self.assertIn("缺少可信发布公钥", out)

    def test_disabled_ufw_matches_proto_from_format(self):
        self.journal("ufw|4|runtime|24443/udp\n")
        self.shell("""
ufw() {
 if [[ "$1" == status ]]; then echo 'Status: inactive'
 elif [[ "$1" == show ]]; then echo "ufw allow in proto udp from 0.0.0.0/0 to any port 24443 comment 'buds-hy2'"
 else echo "ufw $*" >> "$ACTION_FILE"; fi
}
cleanup_firewall
""")
        self.assertEqual(
            self.actions().strip(),
            "ufw --force delete allow in proto udp from 0.0.0.0/0 to any port 24443 comment buds-hy2",
        )
        self.assertFalse((self.config / ".firewall_rule").exists())

    def test_uninstall_preserves_external_periodic_certbot_and_removes_logrotate(self):
        self.node_config()
        periodic = self.directory / "etc/periodic/daily/certbot-renew"
        periodic.parent.mkdir(parents=True)
        periodic.write_text("#!/bin/sh\ncertbot renew\n", encoding="utf-8")
        logrotate = self.directory / "etc/logrotate.d/hysteria"
        logrotate.parent.mkdir(parents=True)
        logrotate.write_text("/var/log/hysteria.log {}\n", encoding="utf-8")
        self.shell("uninstall <<<'y'\n")
        self.assertTrue(periodic.exists())
        self.assertFalse(logrotate.exists())

    def test_get_listen_and_url_encoding_with_special_chars(self):
        self.certificates()
        (self.config / "config.yaml").write_text(
            'listen: 0.0.0.0:8443\nauth:\n  type: password\n  password: "p@ss#1&2"\n'
            'obfs:\n  type: salamander\n  salamander:\n    password: "obf$1+2"\n'
            'masquerade:\n  type: proxy\n  proxy:\n    url: https://example.org/\n',
            encoding="utf-8",
        )
        (self.config / "client.yaml").write_text(
            'server: [2001:db8::1]:8443\ntls:\n  sni: node.example.com\n',
            encoding="utf-8",
        )
        out = self.shell("get_listen\nget_public_ports\nlink\n")
        self.assertIn("8443", out)
        self.assertIn("p%40ss%231%262@", out)
        self.assertIn("obfs-password=obf%241%2B2", out)
        self.assertIn("https://example.org/", out)

    def test_uninstall_failure_preserves_recovery_metadata(self):
        self.node_config()
        self.journal("ufw|-|runtime|24443/udp\n")
        (self.config / ".public_port").write_text("19957\n")
        unit = self.directory / "etc/systemd/system/hysteria-server.service"
        unit.parent.mkdir(parents=True)
        unit.touch()
        out = self.shell("""
has_systemd() { return 0; }
crontab() { echo "no crontab"; return 1; }
ufw() { return 1; }
uninstall 2>&1 <<<'y'
""", expected=1)
        self.assertTrue(self.config.exists())
        self.assertTrue((self.config / ".firewall_rule").exists())
        self.assertTrue(unit.exists())
        self.assertIn("防火墙清理失败", out)

    def test_uninstall_removes_owned_periodic_job_only(self):
        self.node_config()
        periodic = self.directory / "etc/periodic/daily/certbot-renew"
        periodic.parent.mkdir(parents=True)
        periodic.write_text("#!/bin/sh\n# buds-hy2-renew\ncertbot renew\n", encoding="utf-8")
        self.shell("uninstall <<<'y'\n")
        self.assertFalse(periodic.exists())

    def test_uninstall_keeps_old_firewall_journal_if_replacement_fails(self):
        self.node_config()
        journal = "ufw|-|runtime|24443/udp\n"
        self.journal(journal)
        self.shell("""
crontab() { echo "no crontab"; return 1; }
ufw() { return 1; }
mv() { return 1; }
uninstall <<<'y'
""", expected=1)
        self.assertEqual((self.config / ".firewall_rule").read_text(encoding="utf-8"), journal)

    def test_uninstall_can_retry_after_service_definition_was_removed(self):
        self.node_config()
        self.shell("""
has_systemd() { return 0; }
has_openrc() { return 1; }
systemctl() {
    case "$1" in stop|is-active) return 1 ;; esac
}
pgrep() { return 1; }
uninstall <<<'y'
""")
        self.assertFalse(self.config.exists())

    def test_certificate_hook_escapes_domain_and_waits_for_old_process(self):
        (self.directory / "etc/letsencrypt/live/node.example.com").mkdir(parents=True)
        for name in ("fullchain.pem", "privkey.pem"):
            (self.directory / "etc/letsencrypt/live/node.example.com" / name).write_text("certificate")
        # Extract the deployment hook from setup_certificates without issuing a certificate.
        body = self.sources["install.sh"].split("    {\n        printf '#!/usr/bin/env bash", 1)[1]
        body = body.split("    } > \"$HOOK_FILE\"", 1)[0]
        hook_script = "    {\n        printf '#!/usr/bin/env bash" + body + '    } > "$HOOK_FILE"\n'
        self.shell('mkdir -p "$HOOK_DIR"\nDOMAIN=node.example.com\n' + hook_script, "install.sh")
        hook = self.directory / "etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh"
        self.assertIn("DOMAIN=node.example.com", hook.read_text(encoding="utf-8"))
        out = self.shell(f"""
command() {{ if [[ "$1" == -v && "$2" =~ ^(systemctl|rc-service|rc-update|openrc-run)$ ]]; then return 1; fi; builtin command "$@"; }}
pgrep() {{ return 0; }}
pkill() {{ return 0; }}
nohup() {{ echo UNEXPECTED_RESTART >> "$ACTION_FILE"; }}
export -f pgrep pkill nohup command
export SANDBOX ACTION_FILE
bash "$SANDBOX/etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh"
""", expected=1)
        self.assertNotIn("UNEXPECTED_RESTART", self.actions())

    def test_range_port_check_is_awk_compatible(self):
        output = self.shell("""
ss() { printf 'UNCONN 0 0 0.0.0.0:20005 0.0.0.0:* users:(("other",pid=1,fd=1))\\n'; }
validate_domain() { :; }; generate_random_port() { echo 24443; }
generate_random_string() { echo random; }
IS_NAT=false; IS_CONTAINER=false
collect_parameters <<'INPUT'
node.example.com
20000-20010
INPUT
[[ "$LISTEN_STR" == :20000-20010 ]]
""", "install.sh")
        self.assertIn("20005", output)

if __name__ == "__main__":
    unittest.main(verbosity=2)
