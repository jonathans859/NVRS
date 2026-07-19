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
			if not self._authenticate(sock):
				log.warning("NVRS: rejected connection from %s (bad auth)" % (addr[0],))
				client.close()
				return
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

	def _authenticate(self, sock):
		if not self._secret:
			# No secret configured: refuse everything rather than stream openly.
			return False
		sock.settimeout(AUTH_TIMEOUT_SEC)
		line = b""
		while b"\n" not in line:
			if len(line) > 4096:
				return False
			chunk = sock.recv(1024)
			if not chunk:
				return False
			line += chunk
		sock.settimeout(None)
		try:
			payload = json.loads(line.split(b"\n", 1)[0].decode("utf-8"))
			supplied = payload.get("auth", "")
		except (ValueError, AttributeError, UnicodeDecodeError):
			return False
		if not isinstance(supplied, str):
			return False
		return hmac.compare_digest(supplied.encode("utf-8"), self._secret.encode("utf-8"))

	def _senderLoop(self, client):
		while not (self._stopping.is_set() or client.closed.is_set()):
			try:
				data = client.queue.get(timeout=1)
			except queue.Empty:
				continue
			try:
				client.sock.sendall(data)
			except OSError:
				return

	def _readerLoop(self, client):
		# We ignore whatever the client sends after auth, but reading is how
		# we notice a clean disconnect promptly.
		while not client.closed.is_set():
			try:
				if not client.sock.recv(4096):
					break
			except OSError:
				break
		client.close()
