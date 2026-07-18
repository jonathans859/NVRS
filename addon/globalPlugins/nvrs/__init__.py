# NVRS: Non-Visual Remote Speech - NVDA global plugin.
# Mirrors every speech sequence NVDA queues (including SayAll) to the NVRS
# iOS app over a Tailscale TCP connection. See PROTOCOL.md in the repo.

import itertools
import threading

import addonHandler
import config
import globalPluginHandler
import gui
from gui import guiHelper, nvdaControls
from gui.settingsDialogs import NVDASettingsDialog, SettingsPanel
from logHandler import log
from scriptHandler import script
import speech
import speech.extensions
import speech.manager
import synthDriverHandler
import ui
import wx

from . import serializer
from .transport import TcpServerTransport

try:
	addonHandler.initTranslation()
except Exception:
	pass

config.conf.spec["nvrs"] = {
	"enabled": "boolean(default=true)",
	"port": "integer(default=6877, min=1, max=65535)",
	"secret": "string(default='')",
	"bindAddress": "string(default='auto')",
}

SYNTH_POLL_SEC = 3

#: Set while a plugin instance is alive, so the settings panel can reach it.
_plugin = None


def _buildSynthConfig():
	"""Snapshot the active synth's voice/rate/pitch/volume as a synthConfig
	message. Must run on the main thread (touches synth driver state)."""
	synth = synthDriverHandler.getSynth()
	if synth is None:
		return None
	msg = {"type": "synthConfig", "synth": synth.name}
	try:
		if synth.isSupported("voice") and synth.voice:
			msg["voice"] = synth.voice
			voiceInfo = synth.availableVoices.get(synth.voice)
			if voiceInfo is not None:
				msg["voiceName"] = voiceInfo.displayName
				if voiceInfo.language:
					msg["lang"] = voiceInfo.language
	except Exception:
		log.debugWarning("NVRS: could not read voice info", exc_info=True)
	for setting in ("rate", "pitch", "volume"):
		try:
			if synth.isSupported(setting):
				msg[setting] = getattr(synth, setting)
		except Exception:
			log.debugWarning("NVRS: could not read synth %s" % setting, exc_info=True)
	return msg


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	def __init__(self):
		super().__init__()
		global _plugin
		_plugin = self
		self._seq = itertools.count(1)
		self._muted = False
		self._transport = None
		self._lastSynthConfig = None
		self._usingOfficialHook = hasattr(speech.extensions, "pre_speechQueued")
		self._origManagerSpeak = None
		self._registerSpeechHooks()
		synthDriverHandler.synthChanged.register(self._onSynthChanged)
		self._pollStop = threading.Event()
		self._pollThread = threading.Thread(
			target=self._pollLoop, name="NVRS-synthPoll", daemon=True
		)
		self._pollThread.start()
		NVDASettingsDialog.categoryClasses.append(NVRSSettingsPanel)
		self._restartFromConfig()

	def terminate(self):
		global _plugin
		_plugin = None
		self._pollStop.set()
		try:
			NVDASettingsDialog.categoryClasses.remove(NVRSSettingsPanel)
		except ValueError:
			pass
		if self._usingOfficialHook:
			speech.extensions.pre_speechQueued.unregister(self._onSpeechQueued)
		elif self._origManagerSpeak is not None:
			speech.manager.SpeechManager.speak = self._origManagerSpeak
		speech.extensions.speechCanceled.unregister(self._onSpeechCanceled)
		synthDriverHandler.synthChanged.unregister(self._onSynthChanged)
		self._stopTransport()
		super().terminate()

	# --- Hook wiring -----------------------------------------------------

	def _registerSpeechHooks(self):
		if self._usingOfficialHook:
			speech.extensions.pre_speechQueued.register(self._onSpeechQueued)
			log.info("NVRS: using official pre_speechQueued extension point")
		else:
			# Pre-2025 NVDA: patch the speech manager's speak, the single
			# funnel all speech (including SayAll) passes through.
			plugin = self
			origSpeak = speech.manager.SpeechManager.speak
			self._origManagerSpeak = origSpeak

			def patchedSpeak(mgr, speechSequence, *args, **kwargs):
				priority = kwargs.get("priority", args[0] if args else None)
				try:
					plugin._onSpeechQueued(speechSequence=speechSequence, priority=priority)
				except Exception:
					log.error("NVRS: speech hook failed", exc_info=True)
				return origSpeak(mgr, speechSequence, *args, **kwargs)

			speech.manager.SpeechManager.speak = patchedSpeak
			log.info("NVRS: pre_speechQueued unavailable; patched SpeechManager.speak")
		speech.extensions.speechCanceled.register(self._onSpeechCanceled)

	# --- Event handlers --------------------------------------------------

	def _onSpeechQueued(self, speechSequence=None, priority=None, **kwargs):
		transport = self._transport
		if transport is None or self._muted or speechSequence is None:
			return
		try:
			transport.send(serializer.serializeSequence(speechSequence, next(self._seq), priority))
		except Exception:
			log.error("NVRS: failed to forward speech sequence", exc_info=True)

	def _onSpeechCanceled(self, **kwargs):
		transport = self._transport
		if transport is not None and not self._muted:
			transport.send({"type": "cancel"})

	def _onSynthChanged(self, **kwargs):
		wx.CallAfter(self._sendSynthConfig)

	def _onListenerConnected(self):
		# Runs on a transport thread; synth state must be read on the main one.
		wx.CallAfter(self._sendSynthConfig, True)

	def _pollLoop(self):
		# synthChanged only fires on driver switches; a light poll catches
		# plain rate/pitch/volume slider changes.
		while not self._pollStop.wait(SYNTH_POLL_SEC):
			if self._transport is not None:
				wx.CallAfter(self._sendSynthConfig)

	def _sendSynthConfig(self, force=False):
		transport = self._transport
		if transport is None:
			return
		try:
			msg = _buildSynthConfig()
		except Exception:
			log.debugWarning("NVRS: failed to build synthConfig", exc_info=True)
			return
		if msg is None:
			return
		if force or msg != self._lastSynthConfig:
			self._lastSynthConfig = msg
			transport.send(msg)

	# --- Transport lifecycle ---------------------------------------------

	def _restartFromConfig(self):
		self._stopTransport()
		conf = config.conf["nvrs"]
		if not conf["enabled"]:
			log.info("NVRS: disabled in settings")
			return
		if not conf["secret"]:
			log.warning("NVRS: no shared secret configured; not starting the server")
			return
		self._transport = TcpServerTransport(
			port=conf["port"],
			secret=conf["secret"],
			bindAddress=conf["bindAddress"],
		)
		self._transport.onListenerConnected = self._onListenerConnected
		self._lastSynthConfig = None
		self._transport.start()

	def _stopTransport(self):
		if self._transport is not None:
			self._transport.stop()
			self._transport = None

	# --- Scripts ---------------------------------------------------------

	@script(
		# Translators: input help description for the NVRS mute script.
		description=_("Toggles NVRS speech mirroring to the phone (mute for sensitive content)"),
		category="NVRS",
		gesture="kb:NVDA+shift+n",
	)
	def script_toggleMute(self, gesture):
		self._muted = not self._muted
		if self._muted:
			transport = self._transport
			if transport is not None:
				# Stop anything the phone is still speaking.
				transport.send({"type": "cancel"})
			# Translators: announced when NVRS streaming is muted.
			ui.message(_("NVRS muted"))
		else:
			# Translators: announced when NVRS streaming is unmuted.
			ui.message(_("NVRS unmuted"))


class NVRSSettingsPanel(SettingsPanel):
	# Translators: title of the NVRS settings panel.
	title = _("NVRS")

	def makeSettings(self, settingsSizer):
		helper = guiHelper.BoxSizerHelper(self, sizer=settingsSizer)
		conf = config.conf["nvrs"]
		# Translators: label of the enable checkbox in NVRS settings.
		self.enabledCheckbox = helper.addItem(wx.CheckBox(self, label=_("&Enable speech mirroring")))
		self.enabledCheckbox.SetValue(conf["enabled"])
		self.portEdit = helper.addLabeledControl(
			# Translators: label of the port field in NVRS settings.
			_("&Port"),
			nvdaControls.SelectOnFocusSpinCtrl,
			min=1,
			max=65535,
			initial=conf["port"],
		)
		# Translators: label of the shared secret field in NVRS settings.
		self.secretEdit = helper.addLabeledControl(_("Shared &secret"), wx.TextCtrl)
		self.secretEdit.SetValue(conf["secret"])
		self.bindEdit = helper.addLabeledControl(
			# Translators: label of the bind address field in NVRS settings.
			_("&Bind address (auto = Tailscale interface)"),
			wx.TextCtrl,
		)
		self.bindEdit.SetValue(conf["bindAddress"])

	def onSave(self):
		conf = config.conf["nvrs"]
		conf["enabled"] = self.enabledCheckbox.GetValue()
		conf["port"] = self.portEdit.GetValue()
		conf["secret"] = self.secretEdit.GetValue()
		conf["bindAddress"] = self.bindEdit.GetValue().strip() or "auto"
		if _plugin is not None:
			_plugin._restartFromConfig()
