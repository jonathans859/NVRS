#!/usr/bin/env python3
"""Exercise the add-on's handshake outside NVDA.

Drives the real TcpServerTransport on loopback with hand-built client
handshakes, so the security-relevant answers - a stolen response is useless on
the next connection, a wrong secret is refused, and the legacy cleartext
handshake can be switched off - are checked rather than assumed.

Run with: python tools/selftest_auth.py
"""

import hashlib
import hmac
import importlib
import json
import socket
import sys
import types
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HOST = "127.0.0.1"
PORT = 6899
SECRET = "selftest-secret"
NEWLINE = chr(10).encode("ascii")

failures = []
logged = []


def check(label, got, want):
	ok = got == want
	print("%s %s: %r%s" % ("PASS" if ok else "FAIL", label, got, "" if ok else " (want %r)" % (want,)))
	if not ok:
		failures.append(label)


def installLogStub():
	"""transport.py's only NVDA import."""
	class Log:
		def __getattr__(self, level):
			def emit(message, *args, **kwargs):
				logged.append((level, message))
			return emit

	module = types.ModuleType("logHandler")
	module.log = Log()
	sys.modules["logHandler"] = module


def response(nonce, secret=SECRET):
	return hmac.new(secret.encode("utf-8"), nonce.encode("ascii"), hashlib.sha256).hexdigest()


class Handshake:
	"""One connection, up to and including the add-on's verdict."""

	def __init__(self):
		self.sock = socket.create_connection((HOST, PORT), timeout=5)
		self.buf = b""
		self.nonce = self._readLine().get("nonce")

	def _readLine(self):
		while NEWLINE not in self.buf:
			chunk = self.sock.recv(4096)
			if not chunk:
				return {}
			self.buf += chunk
		line, self.buf = self.buf.split(NEWLINE, 1)
		return json.loads(line) if line.strip() else {}

	def send(self, payload):
		self.sock.sendall(json.dumps(payload).encode("utf-8") + NEWLINE)

	def accepted(self):
		"""True when the add-on greeted us rather than hanging up."""
		try:
			return self._readLine().get("type") == "hello"
		except (OSError, ValueError):
			return False

	def close(self):
		try:
			self.sock.close()
		except OSError:
			pass


def attempt(payload):
	shake = Handshake()
	shake.send(payload)
	ok = shake.accepted()
	shake.close()
	return ok


def main():
	installLogStub()
	sys.path.insert(0, str(REPO_ROOT / "addon" / "globalPlugins" / "nvrs"))
	transport = importlib.import_module("transport")

	server = transport.TcpServerTransport(port=PORT, secret=SECRET, bindAddress=HOST)
	server.start()
	try:
		print("-- the challenge itself")
		first = Handshake()
		second = Handshake()
		check("a nonce is issued", bool(first.nonce), True)
		check("nonce is fresh per connection", first.nonce != second.nonce, True)
		stolen = response(first.nonce)
		first.close()
		second.close()

		print("\n-- answering it")
		shake = Handshake()
		shake.send({"auth": response(shake.nonce), "authScheme": "hmac-sha256"})
		check("correct response accepted", shake.accepted(), True)
		shake.close()

		check("wrong secret refused", attempt(
			{"auth": response("whatever", secret="wrong"), "authScheme": "hmac-sha256"}
		), False)
		check("the secret itself is not a valid response", attempt(
			{"auth": SECRET, "authScheme": "hmac-sha256"}
		), False)
		check("unknown scheme refused", attempt(
			{"auth": SECRET, "authScheme": "rot13"}
		), False)

		print("\n-- a recorded response is worth nothing later")
		# The whole point of the nonce: replaying what a listener saw on an
		# earlier connection must not open a new one.
		check("replayed response refused", attempt(
			{"auth": stolen, "authScheme": "hmac-sha256"}
		), False)

		print("\n-- the legacy cleartext handshake")
		logged.clear()
		check("accepted while allowed", attempt({"auth": SECRET}), True)
		check("and warned about", any(
			level == "warning" and "in the clear" in message for level, message in logged
		), True)
		check("wrong secret still refused", attempt({"auth": "nope"}), False)

		transport.ALLOW_LEGACY_PLAINTEXT_AUTH = False
		try:
			check("refused once switched off", attempt({"auth": SECRET}), False)
			shake = Handshake()
			shake.send({"auth": response(shake.nonce), "authScheme": "hmac-sha256"})
			check("challenge still works with it off", shake.accepted(), True)
			shake.close()
		finally:
			transport.ALLOW_LEGACY_PLAINTEXT_AUTH = True
	finally:
		server.stop()

	print("\n%s" % ("All checks passed" if not failures else "FAILED: %s" % ", ".join(failures)))
	return 1 if failures else 0


if __name__ == "__main__":
	sys.exit(main())
