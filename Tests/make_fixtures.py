"""Generate synthetic audio for the recording tests; no recorded music is used."""
from pathlib import Path
import math
import struct
import wave

HERE = Path(__file__).resolve().parent
RATE = 48000


def write_mono(name, samples):
    with wave.open(str(HERE / name), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(b"".join(struct.pack("<h", value) for value in samples))


write_mono("silence.wav", [0] * (RATE * 10))
write_mono("lead-in-tone.wav", (
    round(655 * math.sin(2 * math.pi * 220 * frame / RATE))
    for frame in range(RATE)
))
print("Generated silence.wav and lead-in-tone.wav in Tests/.")

# Separate guitar/vocal frequencies make instrumental exports measurable.
for index, frequency in enumerate((220, 880), 1):
    write_mono(f"bounce-{index}.wav", (
        round(1000 * math.sin(2 * math.pi * frequency * frame / RATE))
        for frame in range(RATE * 2)
    ))
print("Generated bounce-1.wav and bounce-2.wav in Tests/.")

write_mono("mix-tone.wav", (
    round(3277 * math.sin(2 * math.pi * 440 * frame / RATE))
    for frame in range(RATE * 8)
))
print("Generated mix-tone.wav in Tests/.")
