# NVRS: Non-Visual Remote Speech - speech sequence serialization.
# Converts NVDA SpeechSequence items into the NVRS wire format (see PROTOCOL.md).

import time

from logHandler import log
from speech import commands

PRIORITY_NAMES = {0: "normal", 1: "next", 2: "now"}


def _prosody(kind, cmd):
	# BaseProsodyCommand carries either an offset or a multiplier, never
	# both; offset 0 with multiplier 1 means "return to the base setting".
	# Read the private fields: the public properties compute against the
	# synth's configured default, which would bake the PC baseline into
	# what should stay a relative command.
	item = {"type": kind, "offset": int(getattr(cmd, "_offset", 0))}
	multiplier = getattr(cmd, "_multiplier", 1)
	if multiplier != 1:
		item["multiplier"] = float(multiplier)
	return item


def _serializeItem(item):
	if isinstance(item, str):
		return {"type": "text", "value": item}
	if isinstance(item, commands.PitchCommand):
		return _prosody("pitch", item)
	if isinstance(item, commands.RateCommand):
		return _prosody("rate", item)
	if isinstance(item, commands.VolumeCommand):
		return _prosody("volume", item)
	if isinstance(item, commands.LangChangeCommand):
		return {"type": "lang", "lang": item.lang}
	if isinstance(item, commands.CharacterModeCommand):
		return {"type": "characterMode", "on": bool(item.state)}
	if isinstance(item, commands.BreakCommand):
		return {"type": "break", "ms": int(item.time)}
	if isinstance(item, commands.PhonemeCommand):
		return {"type": "phoneme", "ipa": item.ipa, "text": item.text}
	if isinstance(item, commands.IndexCommand):
		return {"type": "index", "index": int(item.index)}
	if isinstance(item, commands.EndUtteranceCommand):
		return {"type": "endUtterance"}
	if isinstance(item, commands.BeepCommand):
		return {
			"type": "beep",
			"hz": item.hz,
			"ms": item.length,
			"left": item.left,
			"right": item.right,
		}
	# WaveFileCommand (earcons reference local files), callback commands,
	# config profile triggers etc. have no meaning on the phone.
	return None


def serializeSequence(sequence, seqNum, priority):
	items = []
	for item in sequence:
		try:
			serialized = _serializeItem(item)
		except Exception:
			log.debugWarning("NVRS: failed to serialize %r" % (item,), exc_info=True)
			continue
		if serialized is not None:
			items.append(serialized)
	return {
		"seq": seqNum,
		"priority": PRIORITY_NAMES.get(int(priority) if priority is not None else 0, "normal"),
		"ts": time.time(),
		"items": items,
	}
