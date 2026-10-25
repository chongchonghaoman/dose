#!/usr/bin/env python3
"""Bake a subtle room response; keep the selected dry shutter recording untouched."""
from array import array
from pathlib import Path
import math
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/LightTableApp/Resources"
SAMPLE_RATE = 48_000
CHANNELS = 2
TAIL_SECONDS = 0.18
# Quiet, slightly asymmetric early reflections with a short, diffuse decay.
REFLECTIONS = ((.019, .024, .045), (.033, .041, .032),
               (.052, .061, .024), (.074, .086, .017),
               (.101, .115, .011), (.134, .148, .006))


def room_response(samples):
    frames = len(samples) // CHANNELS
    tail_frames = round(TAIL_SECONDS * SAMPLE_RATE)
    output_frames = frames + tail_frames
    result = [float(value) for value in samples] + [0.0] * (tail_frames * CHANNELS)
    for channel in range(CHANNELS):
        # Reflections are darker than the dry click, preserving its crisp onset.
        filtered = []
        state = 0.0
        coefficient = 1 - math.exp(-2 * math.pi * 3_600 / SAMPLE_RATE)
        for frame in range(frames):
            state += coefficient * (samples[frame * CHANNELS + channel] - state)
            filtered.append(state)
        for left_delay, right_delay, gain in REFLECTIONS:
            delay = round((left_delay if channel == 0 else right_delay) * SAMPLE_RATE)
            for frame, value in enumerate(filtered):
                result[(frame + delay) * CHANNELS + channel] += value * gain
    # Leave peak headroom instead of clipping the original recording's hot peaks.
    peak = max(abs(value) for value in result)
    gain = min(0.90, 30_000 / max(1, peak))
    fade_frames = round(.0005 * SAMPLE_RATE)
    final_fade_frames = round(.008 * SAMPLE_RATE)
    for frame in range(output_frames):
        fade = min(1, frame / fade_frames, (output_frames - frame - 1) / final_fade_frames)
        for channel in range(CHANNELS):
            index = frame * CHANNELS + channel
            result[index] = round(result[index] * gain * max(0, fade))
    return array("h", result)


def write_wave(path, samples):
    if sys.byteorder != "little":
        samples = array("h", samples)
        samples.byteswap()
    with wave.open(str(path), "wb") as output:
        output.setnchannels(CHANNELS)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(samples.tobytes())


def main():
    with wave.open(str(RESOURCES / "ShutterClick.wav"), "rb") as source:
        assert (source.getframerate(), source.getnchannels(), source.getsampwidth()) == (SAMPLE_RATE, CHANNELS, 2)
        frames = source.getnframes()
        samples = array("h", source.readframes(frames))
    if sys.byteorder != "little":
        samples.byteswap()
    write_wave(RESOURCES / "ShutterClickRoom.wav", room_response(samples))
    # Cut the dry source first, so first entry never contains echoes of the first click.
    write_wave(RESOURCES / "ShutterArrivalRoom.wav", room_response(samples[(frames // 2) * CHANNELS:]))
    print(f"Prepared full shutter ({frames} frames) and latter half ({frames - frames // 2} frames), plus short room tails.")


if __name__ == "__main__":
    main()
