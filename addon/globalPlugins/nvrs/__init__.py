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
import os

import nvwave
import synthDriverHandler
import tones
import ui
import wx

from . import audiomute
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
	# Opt-in only: silencing the PC's own speakers is never done behind
	# the user's back.
	"muteLocalAudio": "boolean(default=false)",
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
		#: True while NVDA's own audio session is muted by us.
		self._pcMuted = False
		self._transport = None
		self._lastSynthConfig = None
		self._usingOfficialHook = hasattr(speech.extensions, "pre_speechQueued")
		self._origManagerSpeak = None
		self._registerSpeechHooks()
		tones.decide_beep.register(self._onDecideBeep)
		nvwave.decide_playWaveFile.register(self._onDecidePlayWaveFile)
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
		tones.decide_beep.unregister(self._onDecideBeep)
		nvwave.decide_playWaveFile.unregister(self._onDecidePlayWaveFile)
		synthDriverHandler.synthChanged.unregister(self._onSynthChanged)
		self._stopTransport()
		# Last chance to give the user their speakers back: an add-on
		# that leaves NVDA muted on the way out is unrecoverable without
		# sighted help.
		if self._pcMuted:
			self._pcMuted = False
			audiomute.forceUnmute()
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

	def _onDecideBeep(
		self, hz=None, length=None, left=50, right=50, isSpeechBeepCommand=False, **kwargs
	):
		# Beeps embedded in speech sequences are already mirrored as
		# envelope items; forwarding them here too would double-beep.
		transport = self._transport
		if transport is not None and not self._muted and not isSpeechBeepCommand and hz:
			transport.send(
				{"type": "beep", "hz": hz, "ms": length, "left": left, "right": right}
			)
		# Always keep playing the beep locally on the PC.
		return True

	def _onDecidePlayWaveFile(self, fileName=None, **kwargs):
		# Sound files themselves live on the PC; forward the basename and
		# let the app play its own bundled copy of known sounds (NVDA's
		# core earcons: browseMode, focusMode, error, ...). Speech-sequence
		# WaveFileCommands are not serialized as envelope items, so
		# forwarding every wave here never doubles.
		transport = self._transport
		if transport is not None and not self._muted and fileName:
			name = os.path.splitext(os.path.basename(fileName))[0]
			transport.send({"type": "wave", "name": name})
		# Always keep playing the sound locally on the PC.
		return True

	def _onSynthChanged(self, **kwargs):
		wx.CallAfter(self._sendSynthConfig)

	def _onListenerConnected(self):
		# Runs on a transport thread; synth state must be read on the main one.
		wx.CallAfter(self._sendSynthConfig, True)
		wx.CallAfter(self._onListenerConnectedMain)

	def _onListenerConnectedMain(self):
		transport = self._transport
		if transport is None:
			return
		# Arm the mute on the first listener only, so a second app joining
		# doesn't undo a mute the user has since toggled off by hand.
		# Never while mirroring itself is muted - that would silence both ends.
		if (
			self._pcMuteAllowed
			and not self._pcMuted
			and not self._muted
			and transport.listenerCount == 1
		):
			self._setPCMute(True)
		else:
			self._sendPCMuteState()

	def _onListenerDisconnected(self):
		wx.CallAfter(self._onListenerDisconnectedMain)

	def _onListenerDisconnectedMain(self):
		# "Until disconnection, then back to normal": the moment the last
		# listener is gone there is nothing left carrying speech to the
		# user, so the PC always gets its voice back.
		transport = self._transport
		if self._pcMuted and (transport is None or transport.listenerCount == 0):
			self._setPCMute(False)

	def _onClientMessage(self, message):
		# Runs on a transport reader thread.
		if message.get("type") == "setPCMute":
			wx.CallAfter(self._handleSetPCMute, message.get("muted"))

	def _handleSetPCMute(self, muted):
		if not self._pcMuteAllowed:
			# The app offered a control it isn't allowed to use (stale
			# state); tell it where things really stand.
			self._sendPCMuteState()
			return
		if muted is None:
			muted = not self._pcMuted
		self._setPCMute(bool(muted))

	def _pollLoop(self):
		# synthChanged only fires on driver switches; a light poll catches
		# plain rate/pitch/volume slider changes.
		while not self._pollStop.wait(SYNTH_POLL_SEC):
			if self._transport is not None:
				wx.CallAfter(self._sendSynthConfig)
			if self._pcMuted:
				wx.CallAfter(audiomute.reassert, True)

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

	# --- Muting the PC's own speakers -------------------------------------

	@property
	def _pcMuteAllowed(self):
		return bool(config.conf["nvrs"]["muteLocalAudio"]) and audiomute.isAvailable()

	def _setPCMute(self, muted):
		"""Mute/unmute NVDA's own audio output and tell the app. Main thread."""
		muted = bool(muted) and self._pcMuteAllowed
		if muted == self._pcMuted:
			self._sendPCMuteState()
			return
		if muted:
			if not audiomute.setMuted(True):
				self._sendPCMuteState()
				return
		else:
			# Unmuting goes through the force path: it re-acquires the
			# session first, so a stale reference can't strand the user
			# with silent speakers.
			audiomute.forceUnmute()
		self._pcMuted = muted
		log.info("NVRS: PC speech %s" % ("muted" if muted else "unmuted"))
		self._sendPCMuteState()

	def _sendPCMuteState(self):
		transport = self._transport
		if transport is not None:
			transport.send(
				{"type": "pcMute", "muted": self._pcMuted, "allowed": self._pcMuteAllowed}
			)

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
		self._transport.onListenerDisconnected = self._onListenerDisconnected
		self._transport.onClientMessage = self._onClientMessage
		self._lastSynthConfig = None
		self._transport.start()

	def _stopTransport(self):
		if self._transport is not None:
			self._transport.stop()
			self._transport = None
		# No transport means no listener, so the mute has nothing left to
		# protect (this also covers "muting turned off in settings", which
		# restarts the transport).
		if self._pcMuted:
			self._pcMuted = False
			audiomute.forceUnmute()

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
			# Nothing carries speech to the phone any more, so silent
			# speakers would leave the user with no output at all.
			if self._pcMuted:
				self._setPCMute(False)
			transport = self._transport
			if transport is not None:
				# Stop anything the phone is still speaking.
				transport.send({"type": "cancel"})
			# Translators: announced when NVRS streaming is muted.
			ui.message(_("NVRS muted"))
		else:
			# Translators: announced when NVRS streaming is unmuted.
			ui.message(_("NVRS unmuted"))

	@script(
		# Translators: input help description for the NVRS PC-mute script.
		description=_("Toggles muting this PC's speech while the NVRS app is connected"),
		category="NVRS",
		gesture="kb:NVDA+shift+m",
	)
	def script_togglePCMute(self, gesture):
		if self._pcMuted:
			# Always allow the way back out, whatever the settings say.
			self._setPCMute(False)
			# Translators: announced when the PC's own speech is turned back on.
			ui.message(_("PC speech on"))
			return
		if not config.conf["nvrs"]["muteLocalAudio"]:
			# Translators: announced when muting the PC is not enabled in settings.
			ui.message(_("Muting this PC is not enabled in NVRS settings"))
			return
		if not audiomute.isAvailable():
			# Translators: announced when the audio mute machinery is unavailable.
			ui.message(_("NVRS cannot control this PC's audio"))
			return
		transport = self._transport
		if transport is None or not transport.listenerCount:
			# Muting with nothing mirroring the speech would leave the
			# user with no output at all.
			# Translators: announced when muting is refused because no app is connected.
			ui.message(_("No NVRS app connected"))
			return
		# Say it before the speakers go quiet - it still reaches the phone,
		# which is where the user is listening from here on.
		# Translators: announced when the PC's own speech is muted.
		ui.message(_("PC speech off"))
		self._setPCMute(True)


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
		self.muteLocalCheckbox = helper.addItem(
			wx.CheckBox(
				self,
				# Translators: label of the mute-this-PC checkbox in NVRS settings.
				label=_("&Mute this PC's speech while the app is connected"),
			)
		)
		self.muteLocalCheckbox.SetValue(conf["muteLocalAudio"])
		self.muteLocalCheckbox.SetToolTip(
			wx.ToolTip(
				# Translators: tooltip of the mute-this-PC checkbox in NVRS settings.
				_(
					"Silences NVDA's own audio output (speech, beeps and sounds) for as "
					"long as the app is connected, so only the phone speaks. Audio comes "
					"back automatically when the app disconnects. NVDA+shift+m toggles it "
					"during a session."
				)
			)
		)
		if not audiomute.isAvailable():
			self.muteLocalCheckbox.Disable()

	def onSave(self):
		conf = config.conf["nvrs"]
		conf["enabled"] = self.enabledCheckbox.GetValue()
		conf["port"] = self.portEdit.GetValue()
		conf["secret"] = self.secretEdit.GetValue()
		conf["bindAddress"] = self.bindEdit.GetValue().strip() or "auto"
		conf["muteLocalAudio"] = self.muteLocalCheckbox.GetValue()
		if _plugin is not None:
			# Restarting drops the listeners, which unmutes; the mute
			# re-arms (or doesn't) when the app reconnects.
			_plugin._restartFromConfig()
