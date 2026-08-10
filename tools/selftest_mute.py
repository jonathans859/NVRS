#!/usr/bin/env python3
"""Exercise the PC-mute flow outside NVDA.

Stubs the NVDA modules the global plugin imports, starts the real transport
on the loopback interface, and drives it with a fake app socket, so the
whole path - connect arms the mute, the app toggles it, disconnect restores
audio - can be checked on any Windows box without installing the add-on.

The Windows audio-session mute really is applied, to *this* Python process
rather than to nvda.exe. Run with: python tools/selftest_mute.py
"""

import builtins
import importlib
import json
import socket
import sys
import threading
import time
import types
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PORT = 6898
SECRET = "selftest-secret"

failures = []


def check(label, got, want):
	ok = got == want
	print("%s %s: %r%s" % ("PASS" if ok else "FAIL", label, got, "" if ok else " (want %r)" % (want,)))
	if not ok:
		failures.append(label)


def installNVDAStubs():
	"""Minimal stand-ins for the NVDA modules the plugin imports."""
	builtins._ = lambda text: text

	def module(name, **attrs):
		mod = types.ModuleType(name)
		for key, value in attrs.items():
			setattr(mod, key, value)
		sys.modules[name] = mod
		return mod

	class Extension:
		def __init__(self):
			self.handlers = []

		def register(self, handler):
			self.handlers.append(handler)

		def unregister(self, handler):
			if handler in self.handlers:
				self.handlers.remove(handler)

	class Log:
		def __getattr__(self, level):
			def emit(message, *args, **kwargs):
				print("    [%s] %s" % (level, message))
			return emit

	class Conf(dict):
		spec = {}

	module("addonHandler", initTranslation=lambda: None)
	module("config", conf=Conf())
	module("globalPluginHandler", GlobalPlugin=type("GlobalPlugin", (), {"terminate": lambda self: None}))
	module("logHandler", log=Log())
	module("scriptHandler", script=lambda **kwargs: (lambda func: func))
	module("ui", message=lambda text: print("    [ui.message] %s" % (text,)))
	module("tones", decide_beep=Extension())
	module("nvwave", decide_playWaveFile=Extension())
	module("synthDriverHandler", synthChanged=Extension(), getSynth=lambda: None)
	module("wx", CallAfter=lambda func, *a, **kw: func(*a, **kw), CheckBox=object, TextCtrl=object, ToolTip=object)

	speech = module("speech")
	# serializer.py type-checks sequence items against these.
	speech.commands = module(
		"speech.commands",
		**{
			name: type(name, (), {})
			for name in (
				"BeepCommand", "BreakCommand", "CharacterModeCommand", "EndUtteranceCommand",
				"IndexCommand", "LangChangeCommand", "PhonemeCommand", "PitchCommand",
				"RateCommand", "VolumeCommand",
			)
		}
	)
	speech.extensions = module("speech.extensions", pre_speechQueued=Extension(), speechCanceled=Extension())
	speech.manager = module(
		"speech.manager",
		SpeechManager=type("SpeechManager", (), {"speak": lambda self, seq, *a, **kw: None}),
	)

	gui = module("gui")
	gui.guiHelper = module("gui.guiHelper", BoxSizerHelper=object)
	gui.nvdaControls = module("gui.nvdaControls", SelectOnFocusSpinCtrl=object)
	gui.settingsDialogs = module(
		"gui.settingsDialogs",
		NVDASettingsDialog=type("NVDASettingsDialog", (), {"categoryClasses": []}),
		SettingsPanel=type("SettingsPanel", (), {}),
	)


class FakeApp:
	"""The iOS app's half of the wire protocol."""

	def __init__(self):
		self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
		self.sock.sendall(json.dumps({"auth": SECRET}).encode("utf-8") + b"\n")
		self.messages = []
		self._buf = b""
		self._stop = threading.Event()
		self._thread = threading.Thread(target=self._read, daemon=True)
		self._thread.start()

	def _read(self):
		while not self._stop.is_set():
			try:
				chunk = self.sock.recv(4096)
			except OSError:
				return
			if not chunk:
				return
			self._buf += chunk
			while b"\n" in self._buf:
				line, self._buf = self._buf.split(b"\n", 1)
				if line.strip():
					self.messages.append(json.loads(line))

	def send(self, message):
		self.sock.sendall(json.dumps(message).encode("utf-8") + b"\n")

	def lastPCMute(self):
		for message in reversed(self.messages):
			if message.get("type") == "pcMute":
				return message
		return None

	def close(self):
		self._stop.set()
		self.sock.close()


def settle(seconds=0.6):
	time.sleep(seconds)


def main():
	installNVDAStubs()
	sys.path.insert(0, str(REPO_ROOT / "addon" / "globalPlugins"))
	nvrs = importlib.import_module("nvrs")
	config = sys.modules["config"]

	if not nvrs.audiomute.isAvailable():
		print("comtypes is unavailable; the OS-level mute cannot be tested here.")
		return 1

	config.conf["nvrs"] = {
		"enabled": True,
		"port": PORT,
		"secret": SECRET,
		"bindAddress": "127.0.0.1",
		"muteLocalAudio": False,
	}
	plugin = nvrs.GlobalPlugin()
	settle()

	def osMuted():
		volume, _deviceId = nvrs.audiomute._acquire()
		return bool(volume.GetMute())

	try:
		print("\n-- opt-out: connecting must not touch the audio")
		app = FakeApp()
		settle()
		check("mute armed while opted out", plugin._pcMuted, False)
		check("app told muting is not allowed", app.lastPCMute(), {"type": "pcMute", "muted": False, "allowed": False})
		app.send({"type": "setPCMute", "muted": True})
		settle()
		check("app request refused while opted out", plugin._pcMuted, False)
		check("OS audio untouched", osMuted(), False)
		app.close()
		settle()

		print("\n-- opt-in: connecting arms the mute, disconnecting clears it")
		config.conf["nvrs"]["muteLocalAudio"] = True
		app = FakeApp()
		settle()
		check("muted on connect", plugin._pcMuted, True)
		check("OS audio session muted", osMuted(), True)
		check("app told the PC is muted", app.lastPCMute(), {"type": "pcMute", "muted": True, "allowed": True})

		print("\n-- the app toggles it")
		app.send({"type": "setPCMute", "muted": False})
		settle()
		check("unmuted on request", plugin._pcMuted, False)
		check("OS audio session unmuted", osMuted(), False)
		app.send({"type": "setPCMute"})
		settle()
		check("bare setPCMute toggles", plugin._pcMuted, True)

		print("\n-- NVDA's shortcut toggles it")
		plugin.script_togglePCMute(None)
		settle()
		check("shortcut unmutes", plugin._pcMuted, False)
		plugin.script_togglePCMute(None)
		settle()
		check("shortcut mutes again", plugin._pcMuted, True)
		check("app saw the PC-side change", app.lastPCMute()["muted"], True)

		print("\n-- muting the stream must not leave the user with no output at all")
		plugin.script_toggleMute(None)
		settle()
		check("stream mute unmutes the PC", plugin._pcMuted, False)
		check("OS audio session unmuted", osMuted(), False)
		plugin.script_toggleMute(None)
		settle()

		print("\n-- disconnect restores the PC's audio")
		plugin.script_togglePCMute(None)
		settle()
		check("muted again", plugin._pcMuted, True)
		app.close()
		settle()
		check("unmuted after the app went away", plugin._pcMuted, False)
		check("OS audio session unmuted", osMuted(), False)

		print("\n-- refusing to mute with nobody listening")
		plugin.script_togglePCMute(None)
		settle()
		check("no mute without a listener", plugin._pcMuted, False)

		print("\n-- terminate() always hands the audio back")
		app = FakeApp()
		settle()
		check("muted on reconnect", plugin._pcMuted, True)
		plugin.terminate()
		settle()
		check("OS audio session unmuted on terminate", osMuted(), False)
		app.close()
	finally:
		# Never leave this process (or a confused tester) muted.
		nvrs.audiomute.forceUnmute()

	print("\n%d checks failed" % (len(failures),) if failures else "\nAll checks passed")
	return 1 if failures else 0


if __name__ == "__main__":
	sys.exit(main())
