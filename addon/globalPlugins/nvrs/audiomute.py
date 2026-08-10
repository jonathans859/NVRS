# NVRS: Non-Visual Remote Speech - silencing the PC's own speakers.
# Part of the NVRS add-on. Stdlib + comtypes (bundled with NVDA) only.
#
# Approach borrowed from Ednunp's remoteSpeechControl add-on: instead of
# zero-filling audio buffers or dropping speech (both of which perturb
# WavePlayer's drain reporting and race the synth-index callbacks that
# SayAll relies on), flip the Windows audio-session mute flag on NVDA's
# own process via WASAPI ISimpleAudioVolume.SetMute. The synth runs
# end-to-end at real timing and every index fires exactly as it would
# without the add-on - only the speakers stop receiving output. That also
# keeps the speech sequences flowing to our own pre_speechQueued hook, so
# the phone still hears everything while the PC is silent.
#
# Note this mutes the whole nvda.exe audio session, i.e. beeps and wave
# earcons as well as the synthesizer. That is intentional: those are
# mirrored to the phone too.

import threading
import time
from ctypes import POINTER, c_bool, c_float, c_int, c_uint, c_void_p
from ctypes.wintypes import LPCWSTR

from logHandler import log

try:
	import comtypes
	from comtypes import COMMETHOD, GUID, CLSCTX_ALL, CoCreateInstance, IUnknown
	_comtypesError = None
except Exception as e:  # pragma: no cover - comtypes ships with NVDA
	comtypes = None
	_comtypesError = e


CLSID_MMDeviceEnumerator = "{BCDE0395-E52F-467C-8E3D-C4579291692E}"

#: EDataFlow.eRender / ERole.eConsole
E_RENDER = 0
E_CONSOLE = 0


if comtypes is not None:

	class ISimpleAudioVolume(IUnknown):
		_iid_ = GUID("{87CE5498-68D6-44E5-9215-6DA47EF883D8}")
		_methods_ = [
			COMMETHOD(
				[], comtypes.HRESULT, "SetMasterVolume",
				(["in"], c_float, "fLevel"),
				(["in"], POINTER(GUID), "EventContext"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "GetMasterVolume",
				(["out"], POINTER(c_float), "pfLevel"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "SetMute",
				(["in"], c_bool, "bMute"),
				(["in"], POINTER(GUID), "EventContext"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "GetMute",
				(["out"], POINTER(c_bool), "pbMute"),
			),
		]

	class IAudioSessionManager2(IUnknown):
		_iid_ = GUID("{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}")
		# Only the two methods we call are declared; comtypes dispatches by
		# name against the declared prefix of the vtable, and everything we
		# need comes before the methods we left out.
		_methods_ = [
			COMMETHOD(
				[], comtypes.HRESULT, "GetAudioSessionControl",
				(["in"], POINTER(GUID), "AudioSessionGuid"),
				(["in"], c_uint, "StreamFlags"),
				(["out"], POINTER(POINTER(IUnknown)), "SessionControl"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "GetSimpleAudioVolume",
				(["in"], POINTER(GUID), "AudioSessionGuid"),
				(["in"], c_uint, "StreamFlags"),
				(["out"], POINTER(POINTER(ISimpleAudioVolume)), "AudioVolume"),
			),
		]

	class IMMDevice(IUnknown):
		_iid_ = GUID("{D666063F-1587-4E43-81F1-B948E807363F}")
		_methods_ = [
			COMMETHOD(
				[], comtypes.HRESULT, "Activate",
				(["in"], POINTER(GUID), "iid"),
				(["in"], c_uint, "dwClsCtx"),
				(["in"], c_void_p, "pActivationParams"),
				(["out"], POINTER(POINTER(IUnknown)), "ppInterface"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "OpenPropertyStore",
				(["in"], c_uint, "stgmAccess"),
				(["out"], POINTER(POINTER(IUnknown)), "ppProperties"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "GetId",
				(["out"], POINTER(LPCWSTR), "ppstrId"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "GetState",
				(["out"], POINTER(c_uint), "pdwState"),
			),
		]

	class IMMDeviceEnumerator(IUnknown):
		_iid_ = GUID("{A95664D2-9614-4F35-A746-DE8DB63617E6}")
		_methods_ = [
			COMMETHOD(
				[], comtypes.HRESULT, "EnumAudioEndpoints",
				(["in"], c_int, "dataFlow"),
				(["in"], c_uint, "dwStateMask"),
				(["out"], POINTER(POINTER(IUnknown)), "ppDevices"),
			),
			COMMETHOD(
				[], comtypes.HRESULT, "GetDefaultAudioEndpoint",
				(["in"], c_int, "dataFlow"),
				(["in"], c_int, "role"),
				(["out"], POINTER(POINTER(IMMDevice)), "ppEndpoint"),
			),
		]


#: Serializes every COM call below; all callers are expected to be on the
#: main thread already, but the mute state is safety-critical enough to
#: guard anyway.
_lock = threading.RLock()
#: Cached ISimpleAudioVolume for NVDA's session, plus the endpoint it was
#: acquired against (so we can notice the default output device changing
#: under us while muted).
_volume = None
_volumeDeviceId = None
_enumerator = None
_lastEndpointCheck = 0.0

#: How often reassert() bothers to look up the current output device.
ENDPOINT_CHECK_INTERVAL_SEC = 10


def isAvailable():
	return comtypes is not None


def _defaultEndpoint():
	global _enumerator
	if _enumerator is None:
		_enumerator = CoCreateInstance(
			GUID(CLSID_MMDeviceEnumerator),
			interface=IMMDeviceEnumerator,
			clsctx=CLSCTX_ALL,
		)
	return _enumerator.GetDefaultAudioEndpoint(E_RENDER, E_CONSOLE)


def _acquire():
	"""Return (volume, deviceId) for NVDA's session on the default output
	device, acquiring it if needed. Returns (None, None) on failure."""
	global _volume, _volumeDeviceId
	if _volume is not None:
		return _volume, _volumeDeviceId
	if comtypes is None:
		log.warning("NVRS: comtypes unavailable, cannot mute NVDA's audio: %r" % (_comtypesError,))
		return None, None
	try:
		device = _defaultEndpoint()
		deviceId = device.GetId()
		manager = device.Activate(IAudioSessionManager2._iid_, CLSCTX_ALL, None).QueryInterface(
			IAudioSessionManager2
		)
		# A NULL session GUID gives us this process's own default audio
		# session - no need to enumerate sessions and match on PID.
		_volume = manager.GetSimpleAudioVolume(None, 0)
		_volumeDeviceId = deviceId
		log.debug("NVRS: acquired audio session volume on endpoint %s" % (deviceId,))
	except Exception:
		log.error("NVRS: could not acquire NVDA's audio session volume", exc_info=True)
		return None, None
	return _volume, _volumeDeviceId


def _release():
	global _volume, _volumeDeviceId
	_volume = None
	_volumeDeviceId = None


def setMuted(muted):
	"""Mute or unmute NVDA's audio session. Returns True on success.

	Call on the main thread (wx.CallAfter from anywhere else).
	"""
	with _lock:
		volume, _deviceId = _acquire()
		if volume is None:
			return False
		try:
			volume.SetMute(bool(muted), None)
		except Exception:
			# Most likely a stale reference (endpoint went away); drop it
			# and try once more with a fresh one.
			log.debug("NVRS: SetMute failed, re-acquiring audio session", exc_info=True)
			_release()
			volume, _deviceId = _acquire()
			if volume is None:
				return False
			try:
				volume.SetMute(bool(muted), None)
			except Exception:
				log.error("NVRS: SetMute(%r) failed" % (muted,), exc_info=True)
				return False
		log.debug("NVRS: NVDA audio session mute set to %r" % (bool(muted),))
		return True


def reassert(muted):
	"""Re-apply `muted` if the default output device changed since we
	acquired our session reference.

	Switching output device (unplugging headphones, Bluetooth dropping)
	moves NVDA onto a fresh, unmuted session on the new endpoint while our
	mute stays behind on the old one - the PC would start talking again
	with no user action. Meant to be called from the add-on's existing poll
	loop; does nothing while unmuted, and rate-limits the device lookup
	itself, so calling it more often than needed is harmless.
	"""
	global _lastEndpointCheck
	if not muted:
		return
	with _lock:
		if _volume is None:
			setMuted(True)
			return
		now = time.monotonic()
		if now - _lastEndpointCheck < ENDPOINT_CHECK_INTERVAL_SEC:
			return
		_lastEndpointCheck = now
		try:
			currentId = _defaultEndpoint().GetId()
		except Exception:
			log.debug("NVRS: could not read the default audio endpoint", exc_info=True)
			return
		if currentId != _volumeDeviceId:
			log.info("NVRS: default audio device changed while muted; re-applying mute")
			_release()
			setMuted(True)


def forceUnmute():
	"""Unmute unconditionally, from a freshly acquired session reference.

	The safety net for teardown paths (disconnect, add-on disable, NVDA
	exit): leaving NVDA's audio session muted with nothing left to unmute
	it would be near-impossible for a blind user to diagnose.
	"""
	with _lock:
		_release()
		if not setMuted(False):
			log.warning("NVRS: could not unmute NVDA's audio session")
