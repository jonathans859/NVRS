# NVRS: Non-Visual Remote Speech - transport layer.
# Part of the NVRS add-on. Stdlib only: NVDA add-ons cannot install packages.

import hmac
import ipaddress
import json
import queue
import socket
import threading

from logHandler import log

#: Connecting to Tailscale's MagicDNS resolver routes via the Tailscale
#: interface, so the socket's local address is this machine's tailnet IP.
_TAILSCALE_PROBE_ADDR = ("100.100.100.100", 53)
_TAILSCALE_CGNAT_NET = ipaddress.ip_network("100.64.0.0/10")

AUTH_TIMEOUT_SEC = 10
CLIENT_QUEUE_SIZE = 256
BIND_RETRY_SEC = 10
#: Control messages from the app are tiny; anything longer is junk or an
#: attempt to make us buffer without bound.
MAX_CLIENT_LINE_BYTES = 4096


#: Wire-protocol version. Bumped ONLY for breaking changes -- a removed or
#: redefined field, or a change to the framing. Additive changes (a new field, a
#: new control message "type") must NOT bump it, because both ends ignore what they
#: do not recognise; that rule is what keeps this number stable enough to be worth
#: checking at all.
PROTOCOL_VERSION = 1
#: Oldest peer protocol this add-on still speaks.
MIN_PROTOCOL_VERSION = 1

def detectTailscaleIP():
	"""Best-effort detection of this machine's Tailscale IPv4 address.
	Returns None when Tailscale is down or not installed.
	"""
	try:
		s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
		try:
			s.connect(_TAILSCALE_PROBE_ADDR)
			ip = s.getsockname()[0]
		finally:
			s.close()
		if ipaddress.ip_address(ip) in _TAILSCALE_CGNAT_NET:
			return ip
	except OSError:
		pass
	return None


class SpeechTransport:
	"""Abstract transport carrying NVRS messages to listeners.

	The rest of the add-on only talks to this interface, so a relay
	transport (e.g. WSS through a VPS) can be dropped in later.
	"""

	#: Called with no arguments from an arbitrary thread whenever a new
	#: listener completes its handshake; the plugin uses it to send the
	#: current synthConfig greeting.
	onListenerConnected = None

	#: Called with no arguments from an arbitrary thread whenever a
	#: listener goes away; check `listenerCount` for how many are left.
	onListenerDisconnected = None

	#: Called with one decoded dict from an arbitrary thread for every
	#: control message a listener sends us after the handshake.
	onClientMessage = None
	#: Called with a human-readable reason when a peer is refused for speaking
	#: an incompatible protocol. The transport has no business talking to the
	#: user, but the user is the only one who can fix it -- so it hands the
	#: message up to the plugin, which reports it through NVDA.
	onProtocolMismatch = None


	def start(self):
		raise NotImplementedError

	def stop(self):
		raise NotImplementedError

	def send(self, message):
		"""Queue a JSON-serializable dict for delivery. Never blocks."""
		raise NotImplementedError

	@property
	def isRunning(self):
		raise NotImplementedError

	@property
	def listenerCount(self):
		"""Number of listeners currently past the handshake."""
		raise NotImplementedError


class _Client:
	def __init__(self, sock, addr):
		self.sock = sock
		self.addr = addr
		self.queue = queue.Queue(maxsize=CLIENT_QUEUE_SIZE)
		self.closed = threading.Event()

	def enqueue(self, data):
		# Live mirror: when the phone can't keep up, drop the oldest
		# utterance rather than blocking NVDA or growing without bound.
		while True:
			try:
				self.queue.put_nowait(data)
				return
			except queue.Full:
				try:
					self.queue.get_nowait()
				except queue.Empty:
					pass

	def close(self):
		if not self.closed.is_set():
			self.closed.set()
			try:
				self.sock.shutdown(socket.SHUT_RDWR)
			except OSError:
				pass
			try:
				self.sock.close()
			except OSError:
				pass


class TcpServerTransport(SpeechTransport):
	"""Listens for NVRS app connections on a TCP port bound to the
	Tailscale interface (or an explicit address), speaking NDJSON.

	First line from the client must be {"auth": "<secret>"}; anything else
	closes the connection.
	"""

	def __init__(self, port, secret, bindAddress="auto"):
		self._port = port
		self._secret = secret
		self._bindAddress = bindAddress
		self._clients = []
		self._clientsLock = threading.Lock()
		self._stopping = threading.Event()
		self._serverSock = None
		self._acceptThread = None

	@property
	def isRunning(self):
		return self._acceptThread is not None and self._acceptThread.is_alive()

	@property
	def listenerCount(self):
		with self._clientsLock:
			return len(self._clients)

	def start(self):
		self._stopping.clear()
		self._acceptThread = threading.Thread(
			target=self._acceptLoop, name="NVRS-accept", daemon=True
		)
		self._acceptThread.start()

	def stop(self):
		self._stopping.set()
		sock = self._serverSock
		self._serverSock = None
		if sock:
			try:
				sock.close()
			except OSError:
				pass
		with self._clientsLock:
			clients = list(self._clients)
			self._clients.clear()
		for client in clients:
			client.close()

	def send(self, message):
		try:
			data = (json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n").encode(
				"utf-8"
			)
		except (TypeError, ValueError):
			log.error("NVRS: unserializable message dropped", exc_info=True)
			return
		with self._clientsLock:
			clients = list(self._clients)
		for client in clients:
			client.enqueue(data)

	def _resolveBindAddress(self):
		if self._bindAddress and self._bindAddress != "auto":
			return self._bindAddress
		return detectTailscaleIP()

	def _acceptLoop(self):
		while not self._stopping.is_set():
			bindAddr = self._resolveBindAddress()
			if bindAddr is None:
				log.debugWarning(
					"NVRS: no Tailscale interface found; retrying in %ds" % BIND_RETRY_SEC
				)
				self._stopping.wait(BIND_RETRY_SEC)
				continue
			try:
				serverSock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
				# Other components in the NVDA process may set a global
				# socket.setdefaulttimeout; force blocking mode so accept()
				# doesn't spuriously time out.
				serverSock.settimeout(None)
				serverSock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
				serverSock.bind((bindAddr, self._port))
				serverSock.listen(2)
			except OSError:
				log.error(
					"NVRS: could not listen on %s:%d; retrying in %ds"
					% (bindAddr, self._port, BIND_RETRY_SEC),
					exc_info=True,
				)
				try:
					serverSock.close()
				except OSError:
					pass
				self._stopping.wait(BIND_RETRY_SEC)
				continue
			self._serverSock = serverSock
			log.info("NVRS: listening on %s:%d" % (bindAddr, self._port))
			try:
				while not self._stopping.is_set():
					try:
						clientSock, addr = serverSock.accept()
					except socket.timeout:
						# Defensive: keep accepting on the same socket.
						continue
					clientSock.settimeout(None)
					threading.Thread(
						target=self._handshakeAndServe,
						args=(clientSock, addr),
						name="NVRS-client-%s" % (addr[0],),
						daemon=True,
					).start()
			except OSError:
				# Server socket closed (stop()) or bind address vanished
				# (Tailscale went down); loop re-binds unless stopping.
				try:
					serverSock.close()
				except OSError:
					pass
				continue

	def _handshakeAndServe(self, sock, addr):
		client = _Client(sock, addr)
		try:
			sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
			payload = self._authenticate(sock)
			if payload is None:
				log.warning("NVRS: rejected connection from %s (bad auth)" % (addr[0],))
				client.close()
				return
			refusal = self._protocolRefusal(payload)
			if refusal is not None:
				# Say why, THEN close. A silent close is indistinguishable from a
				# wrong secret, a firewall, or Tailscale being down, and the user
				# would go looking at the wrong problem entirely.
				self._sendLine(sock, {"type": "error", "code": "protocol", "message": refusal})
				log.warning("NVRS: refused %s -- %s" % (addr[0], refusal))
				client.close()
				callback = self.onProtocolMismatch
				if callback:
					try:
						callback(refusal)
					except Exception:
						log.error("NVRS: onProtocolMismatch failed", exc_info=True)
				return
			# Before anything else, so a version-aware app knows what it is talking
			# to. An older app ignores an unrecognised "type" and is unaffected.
			self._sendLine(sock, {
				"type": "hello",
				"protocol": PROTOCOL_VERSION,
				"minProtocol": MIN_PROTOCOL_VERSION,
				"server": "NVRS add-on",
			})
		except OSError:
			client.close()
			return
		log.info("NVRS: client connected from %s" % (addr[0],))
		with self._clientsLock:
			self._clients.append(client)
		threading.Thread(
			target=self._readerLoop, args=(client,), name="NVRS-reader", daemon=True
		).start()
		callback = self.onListenerConnected
		if callback:
			try:
				callback()
			except Exception:
				log.error("NVRS: onListenerConnected failed", exc_info=True)
		try:
			self._senderLoop(client)
		finally:
			with self._clientsLock:
				if client in self._clients:
					self._clients.remove(client)
			client.close()
			log.info("NVRS: client %s disconnected" % (addr[0],))
			callback = self.onListenerDisconnected
			if callback:
				try:
					callback()
				except Exception:
					log.error("NVRS: onListenerDisconnected failed", exc_info=True)

	def _authenticate(self, sock):
		"""Read the handshake line. Returns the parsed payload, or None if the
		secret is wrong or the line is unusable."""
		if not self._secret:
			# No secret configured: refuse everything rather than stream openly.
			return None
		sock.settimeout(AUTH_TIMEOUT_SEC)
		line = b""
		while b"\n" not in line:
			if len(line) > 4096:
				return None
			chunk = sock.recv(1024)
			if not chunk:
				return None
			line += chunk
		sock.settimeout(None)
		try:
			payload = json.loads(line.split(b"\n", 1)[0].decode("utf-8"))
			supplied = payload.get("auth", "")
		except (ValueError, AttributeError, UnicodeDecodeError):
			return None
		if not isinstance(supplied, str):
			return None
		if not hmac.compare_digest(supplied.encode("utf-8"), self._secret.encode("utf-8")):
			return None
		return payload if isinstance(payload, dict) else {}

	def _sendLine(self, sock, message):
		"""One NDJSON line straight down the socket, outside the sender queue --
		used for the hello and for refusals, which must be ordered before anything
		else and must survive the client never being enqueued."""
		try:
			text = json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n"
			sock.sendall(text.encode("utf-8"))
		except OSError:
			pass

	def _protocolRefusal(self, payload):
		"""None if the peer is compatible, else a message naming which half is out
		of date. A handshake with no "protocol" key predates versioning entirely and
		is treated as protocol 1 -- without that, the first version-aware add-on
		would refuse every app already installed."""
		peer = payload.get("protocol", 1)
		peerMin = payload.get("minProtocol", peer)
		if not isinstance(peer, int) or not isinstance(peerMin, int):
			return "The NVRS app sent a handshake this add-on could not read."
		if peer < MIN_PROTOCOL_VERSION:
			return (
				"The NVRS app on your device is too old for this add-on (app speaks "
				"protocol %d, this add-on needs at least %d). Update the app from "
				"TestFlight." % (peer, MIN_PROTOCOL_VERSION)
			)
		if peerMin > PROTOCOL_VERSION:
			return (
				"This NVRS add-on is too old for the app on your device (add-on speaks "
				"protocol %d, the app needs at least %d). Update the add-on from "
				"github.com/jonathans859/NVRS/releases." % (PROTOCOL_VERSION, peerMin)
			)
		return None

	def _senderLoop(self, client):
		sent = 0
		while not (self._stopping.is_set() or client.closed.is_set()):
			try:
				data = client.queue.get(timeout=1)
			except queue.Empty:
				continue
			try:
				client.sock.sendall(data)
			except OSError:
				log.info(
					"NVRS: send to %s failed after %d messages" % (client.addr[0], sent),
					exc_info=True,
				)
				return
			sent += 1
			if sent == 1:
				log.info(
					"NVRS: first payload (%d bytes) delivered to %s" % (len(data), client.addr[0])
				)
			elif sent % 100 == 0:
				log.debug("NVRS: %d messages delivered to %s" % (sent, client.addr[0]))

	def _readerLoop(self, client):
		# Reading is how we notice a clean disconnect promptly, and how the
		# app sends us control messages (NDJSON, same shape as our own).
		buf = b""
		while not client.closed.is_set():
			try:
				chunk = client.sock.recv(4096)
			except OSError:
				break
			if not chunk:
				break
			buf += chunk
			while b"\n" in buf:
				line, buf = buf.split(b"\n", 1)
				self._dispatchClientLine(line)
			if len(buf) > MAX_CLIENT_LINE_BYTES:
				log.warning("NVRS: oversized line from %s; dropping client" % (client.addr[0],))
				break
		client.close()

	def _dispatchClientLine(self, line):
		line = line.strip()
		if not line:
			return
		try:
			message = json.loads(line.decode("utf-8"))
		except (ValueError, UnicodeDecodeError):
			log.debugWarning("NVRS: unparseable line from client", exc_info=True)
			return
		if not isinstance(message, dict):
			return
		callback = self.onClientMessage
		if callback:
			try:
				callback(message)
			except Exception:
				log.error("NVRS: onClientMessage failed", exc_info=True)
