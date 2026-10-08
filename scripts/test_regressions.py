"""Targeted HY2 regressions using temporary files and mocked system commands.

Run: python scripts/test_regressions.py (Python 3 and Bash required).
"""
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

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
        self.sources = {}
        for name in ("buds", "install.sh"):
            source = (ROOT / name).read_text(encoding="utf-8")
            source = source.rsplit('\nmain "$@"', 1)[0] if name == "install.sh" else source.rsplit("\ncheck_root\n", 1)[0]
            # Redirect absolute runtime paths before loading the real function definitions.
            for prefix in ("/etc/", "/usr/local/", "/var/log/", "/run/"):
                source = source.replace(prefix, self.sandbox + prefix)
            self.sources[name] = source

    def shell(self, script, source="buds", expected=0):
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
setcap() {{ :; }}
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
            text=True, encoding="utf-8", capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def actions(self):
        return (self.directory / "actions").read_text(encoding="utf-8")

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
        self.assertIn("insecure=1&allowInsecure=1", output)
        self.assertIn("insecure: true", output)
        shutil.copyfile(self.directory / "signed.crt", self.config / "server.crt")
        for source in ("buds", "install.sh"):
            self.shell("if is_cert_self_signed; then exit 9; fi\n", source)
        output = self.shell("link\nclient\n")
        self.assertIn("insecure=0&allowInsecure=0", output)
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
        self.assertIn("insecure: true", (self.config / "client.yaml").read_text())
        self.assertEqual((self.config / ".public_port").read_text().strip(), "19957")

    def test_invalid_certificate_does_not_disable_validation(self):
        (self.config / "server.crt").write_text("invalid certificate")
        self.shell("if is_cert_self_signed; then exit 9; fi\n", "install.sh")

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
        unit = (self.directory / "etc/systemd/system/hysteria-server.service").read_text()
        self.assertIn("ExecStart=", unit)
        self.assertIn("hysteria server --config", unit)
        self.assertIn("WantedBy=multi-user.target", unit)
        self.assertIn("AmbientCapabilities=CAP_NET_ADMIN", unit)
        self.assertTrue((self.directory / "etc/systemd/system/hysteria-server.service.d/override.conf").exists())
        self.assertIn("systemctl daemon-reload", self.actions())

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
        self.assertEqual((self.config / ".firewall_rule").read_text(), "ufw|4|runtime|80/tcp\n")

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
        for name in ("buds", "hy2", "hysteria", "hysteria-service"):
            (binary_dir / name).write_text("old-install")
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
        self.assertEqual((self.config / "config.yaml").read_text(), "new.example.com\nnew-password\n")

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
        self.assertEqual((self.config / ".firewall_rule").read_text(), "firewalld|public|permanent|24443/udp\n")
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
        self.assertEqual((self.config / ".firewall_rule").read_text(), "ufw|4|runtime|24443/udp\n")

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
        self.assertEqual(startup.read_text(), "#!/bin/sh\necho keep-this\nexit 0\n")

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
        yaml = (self.config / "client.yaml").read_text()
        self.assertEqual(yaml.count("pinSHA256:"), 1)
        self.assertIn("pinSHA256: " + expected, yaml)
        shutil.copyfile(self.directory / "signed.crt", self.config / "server.crt")
        output = self.shell("link\nclient\n")
        self.assertNotIn("pinSHA256", output)
        self.assertIn("insecure: false", output)

    def test_pin_is_added_when_existing_yaml_has_no_tls_block(self):
        self.certificates()
        self.node_config()
        (self.config / "client.yaml").write_text(
            "server: node.example.com:19957\nauth: keep-me\n", newline="\n"
        )
        self.shell("client\n")
        result = (self.config / "client.yaml").read_text()
        self.assertIn("auth: keep-me", result)
        self.assertIn("pinSHA256:", result)
        self.assertIn("insecure: true", result)

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
        self.assertEqual(binary.read_text(), "existing-core")
        self.assertNotIn("VALIDATE", self.actions())
        self.assertFalse(list(binary.parent.glob(".buds-hy2-download.*")))

    def test_verified_download_is_fixed_version_and_temp_is_removed(self):
        self.shell(self.download_fixture() + "install_official_core\n", "install.sh")
        binary = self.directory / "usr/local/bin/hysteria"
        self.assertEqual(binary.read_text(), "test-core-fixture")
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
            self.assertEqual(binary.read_text(), "existing-core")
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
        unit = (self.directory / "etc/systemd/system/buds-hy2-renew.service").read_text()
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
        self.assertEqual(path.read_text(), contents)
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
        self.assertEqual(root_cron.read_text().count("# buds-hy2-renew"), 1)
        self.shell(common + "cleanup_renewal\n")
        self.assertEqual(root_cron.read_text(), original)

    def test_crontab_read_failure_never_overwrites_other_jobs(self):
        self.shell("""
crontab() { if [[ "$1" == -l ]]; then echo 'permission denied' >&2; return 1; else echo OVERWRITE >> "$ACTION_FILE"; fi; }
cleanup_renewal
""", expected=1)
        self.assertNotIn("OVERWRITE", self.actions())


if __name__ == "__main__":
    unittest.main(verbosity=2)
