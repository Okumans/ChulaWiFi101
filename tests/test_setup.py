"""Run with python3 -m unittest discover -s tests. No real network commands run."""

import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "setup-chulawifi.sh"


class CertificateOptionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "commands.log"
        self.cert = self.root / "certificate.pem"
        self.cert.write_text("mock certificate\n")
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                        TEST_LOG=str(self.log), TEST_OPENSSL_STATUS="1")
        mocks = {
            "openssl": 'exit "$TEST_OPENSSL_STATUS"',
            "systemctl": "exit 0",
            "sudo": "exit 99",
            "nmcli": '''case "$*" in
    '-t -f DEVICE,TYPE device status') printf 'wlan0:wifi\\n' ;;
    '-g connection.type connection show id ChulaWiFi') printf '802-11-wireless\\n' ;;
esac''',
        }
        for name, body in mocks.items():
            path = self.root / name
            path.write_text(
                '#!/bin/bash\nprintf "%s" "${0##*/}" >> "$TEST_LOG"\n'
                'printf " <%s>" "$@" >> "$TEST_LOG"\n'
                'printf "\\n" >> "$TEST_LOG"\n' + body + "\n"
            )
            path.chmod(0o755)

    def run_setup(self, *args, answers=None):
        if answers is None:
            return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                                  input="", capture_output=True, text=True, timeout=5)
        master, slave = pty.openpty()
        try:
            os.write(master, answers.encode())
            return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                                  stdin=slave, capture_output=True, text=True, timeout=5)
        finally:
            os.close(slave)
            os.close(master)

    def assert_no_network_changes(self):
        commands = self.log.read_text() if self.log.exists() else ""
        self.assertNotIn("nmcli", commands)
        self.assertNotIn("systemctl", commands)
        self.assertNotIn("sudo", commands)

    def test_conflicting_options_are_rejected(self):
        result = self.run_setup("--cert-path", str(self.cert),
                                "--dangerously-skip-server-cert-verification")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not both", result.stderr)
        self.assert_no_network_changes()

    def test_invalid_certificate_is_rejected(self):
        result = self.run_setup("--cert-path", str(self.cert))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not read the PEM certificate", result.stderr)
        self.assert_no_network_changes()

    def test_no_certificate_without_terminal_is_rejected(self):
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Use --cert-path PATH", result.stderr)
        self.assert_no_network_changes()

    def test_empty_confirmation_defaults_to_no(self):
        result = self.run_setup(answers="\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rerun with --cert-path PATH", result.stderr)
        self.assert_no_network_changes()

    def test_explicit_bypass_clears_certificate_and_domain(self):
        result = self.run_setup("--dangerously-skip-server-cert-verification",
                                answers="test-identity\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fake AP could steal", result.stderr)
        commands = self.log.read_text()
        self.assertIn("<802-1x.ca-cert> <>", commands)
        self.assertIn("<802-1x.domain-match> <>", commands)
        self.assertFalse(any(line.startswith("openssl ") for line in commands.splitlines()))
        self.assertNotIn("sudo", commands)

    def test_valid_certificate_enables_domain_check(self):
        self.env["TEST_OPENSSL_STATUS"] = "0"
        result = self.run_setup("--cert-path", str(self.cert), answers="test-identity\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text()
        self.assertIn(f"<802-1x.ca-cert> <{self.cert}>", commands)
        self.assertIn("<802-1x.domain-match> <wifi.it.chula.ac.th>", commands)
        self.assertNotIn("sudo", commands)
