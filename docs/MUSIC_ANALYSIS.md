# Music analysis and calibration

Track analysed: **`Roblox_game_finished.mp3`**, 24.79 s, 44.1 kHz stereo, 128 kbps.

## Method

The track was decoded with ffmpeg and analysed in Python (numpy + librosa 1.0):

1. **Tempo**: spectral-flux onset envelope plus a comb-filtered autocorrelation over 60–200 BPM, on the full band and on low (<200 Hz) and high (1.5–6 kHz) bands separately.
2. **Structure**: RMS loudness at 5 ms resolution, plus pYIN pitch tracking of the bass line.
3. **Grid fit**: a brute-force search over BPM (88–92, step 0.05) and first-beat offset (5 ms step), maximising onset and chroma-novelty energy on the beat grid.

Librosa's stock `beat_track` reported 117 BPM. That is **wrong for this track**: the music has almost no percussive transients (only 2 hard onsets are detected in 25 s), so the tracker falls back on its 120 BPM prior. The tempo was therefore taken from the full-band and high-band autocorrelation, chroma novelty and the bass-line chord changes, which all agree.

## Results

| Measurement | Value | Confidence |
|---|---|---|
| Tempo | **90.00 BPM** (beat = 0.6667 s, bar = 2.667 s) | high: full-band, high-band and chroma novelty all peak at 90 |
| Metre | 4/4 | high: bass changes once per 4 beats |
| First downbeat (section 1) | **0.085 s** | high: grid fit score 77.8 at exactly 90.00 BPM |
| Section 1, CHANT | 0.085 → 10.752 s = **16 beats / 4 bars** | high: loudness drops exactly at beat 16 |
| STING (held high D5) | 10.752 → 13.13 s | high: pitch tracker, near-silence in the other bands |
| Section 2, LOOP | **13.13 s** → 23.797 s = 16 beats / 4 bars, D/A bass alternating per bar | medium (±40 ms): soft pad attacks; the downbeat is the onset at 13.13 s and the chord changes average 2.64 s apart |
| Low-band 135 BPM peak | 3-against-2 figure in section 2 (1.5 × 90) | not the pulse |

How the game uses it (`Config.Music`, `Shared/MusicTimeline.lua`):

```
beat  0 … 15   CHANT   one chant syllable per beat ("CON · CEN · TRA · TION, SIX · TY · FOUR, …")
beat 16 … 19   STING   "THE CATEGORY IS…" → the category is revealed
beat 20 …      LOOP    gameplay; the 4-bar loop repeats via Sound.LoopRegion (13.13 → 23.797 s)
turns          start and end on beats; BeatsPerTurn = 8 → 5.33 s per answer
```

## Uploading the track

1. Creator Dashboard → Development Items → **Audio** → upload the mp3 (it must pass moderation).
2. Copy the asset id into `Config.Music.SoundId = "rbxassetid://<id>"`.
3. With `SoundId = ""` the game runs in **silent mode**: the metronome, bulb, chant and timers still follow the same timeline.

## Calibrating (if the visuals feel early or late)

Audio output latency differs per device. To tune:

1. Press **Play** in Studio and start a match. The chant section is the easiest to judge.
2. In the Explorer select **ReplicatedStorage › Shared › Config** and add a **Number attribute** named `AudioOffset`. Clients read it live; no restart needed.
3. Positive values (for example `0.05`) make the beat visuals happen **later** relative to the audio; negative values make them happen earlier. Adjust until the metronome and bulb hit with the clap.
4. Copy the final value into `Config.Music.AudioOffset` and delete the attribute.

If you replace the song with a different track, re-measure and update `BPM`, `ChantStart`, `ChantBeats`, `StingBeats`, `LoopStart` and `LoopBeats`. Every other part of the game derives its timing from these values.
