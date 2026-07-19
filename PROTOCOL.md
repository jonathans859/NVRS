# NVRS wire protocol (v1)

Newline-delimited JSON (NDJSON) over a raw TCP socket. The NVDA add-on
listens on the Tailscale interface; the iOS app connects out to
`<tailscale-ip>:<port>` (default port **6877**). UTF-8 throughout; one JSON
object per line.

## Handshake

First line from the client:

```json
{"auth": "<shared secret>"}
```

The add-on closes the connection unless the secret matches (constant-time
comparison). Immediately after a successful handshake the add-on sends the
current `synthConfig`. The server never reads anything else from the client.

## Server → client messages

Messages with a top-level `"type"` key are control messages; anything else is
a speech envelope.

### Speech envelope

One NVDA `SpeechSequence` (the fully processed form NVDA hands to the
synthesizer — symbols expanded, spelling already split into characters):

```json
{
  "seq": 1234,
  "priority": "now|next|normal",
  "ts": 1737200000.123,
  "items": [
    {"type": "text", "value": "Hello world"},
    {"type": "pitch", "offset": 30},
    {"type": "rate", "offset": -5, "multiplier": 0.5},
    {"type": "volume", "offset": 0},
    {"type": "lang", "lang": "de_DE"},
    {"type": "characterMode", "on": true},
    {"type": "break", "ms": 300},
    {"type": "phoneme", "ipa": "…", "text": "fallback text"},
    {"type": "index", "index": 42},
    {"type": "endUtterance"},
    {"type": "beep", "hz": 550, "ms": 50, "left": 50, "right": 50}
  ]
}
```

Prosody items (`pitch`, `rate`, `volume`): NVDA commands carry *either* an
offset (added to the 0–100 base setting) *or* a multiplier, never both. When
`multiplier` is present use it; otherwise use `offset`; `offset: 0` with no
`multiplier` means *reset to base*. The receiver applies these relative
changes on top of its **own local baseline**, not NVDA's.

`lang` may be `null` → revert to the default voice. `characterMode` brackets
runs of single-character strings that should be spoken as characters.
`index` markers have no audio effect (kept for a future transcript view).
`endUtterance` forces an utterance break.

### Control messages

```json
{"type": "cancel"}
```
Stop current speech and clear the queue immediately (mirrors NVDA's own
interrupt). A speech envelope with `"priority": "now"` implies the same
before speaking.

```json
{"type": "beep", "hz": 550, "ms": 50, "left": 50, "right": 50}
```
A standalone beep outside any speech sequence (progress bars, add-on
sounds; captured via NVDA's `tones.decide_beep`). Played immediately on
arrival, independent of the speech queue. Beeps *inside* speech sequences
travel as envelope items instead (`isSpeechBeepCommand` beeps are not
forwarded here, avoiding doubles).

```json
{"type": "synthConfig", "synth": "oneCore", "voice": "…", "voiceName": "…",
 "lang": "en_US", "rate": 50, "pitch": 50, "volume": 100}
```
Sent at connect and whenever NVDA's synth settings change. Informational for
the iOS app in v1 (offsets are applied to the phone-local baseline), but
carried so a future client can mirror the PC baseline exactly. All fields
except `type` and `synth` are optional (drivers vary).
