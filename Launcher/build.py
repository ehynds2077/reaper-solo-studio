"""Build a local, movable macOS launcher: python3 Launcher/build.py [output.app]."""
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
output = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else Path.home()/'Desktop/Solo Studio.app'
if output.exists():
    raise SystemExit('Destination already exists; choose a new output path: ' + str(output))
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='solo-studio-launcher-') as temporary:
    bundle = Path(temporary)/'Solo Studio.app'
    contents = bundle/'Contents'
    (contents/'MacOS').mkdir(parents=True)
    (contents/'Resources').mkdir()
    subprocess.run(['/usr/bin/swiftc', '-target', platform.machine() + '-apple-macos11.0',
                    '-module-cache-path', str(Path(temporary)/'module-cache'),
                    str(root/'main.swift'), '-o', str(contents/'MacOS/SoloStudio')], check=True)
    shutil.copy2(root/'launch.lua', contents/'Resources/launch.lua')
    plist = {'CFBundleIdentifier': 'com.solostudio.reaper-launcher',
             'CFBundleName': 'Solo Studio', 'CFBundleDisplayName': 'Solo Studio',
             'CFBundleExecutable': 'SoloStudio', 'CFBundlePackageType': 'APPL',
             'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
             'LSMinimumSystemVersion': '11.0', 'LSUIElement': True,
             'NSHighResolutionCapable': True}
    icon = Path('/Applications/REAPER.app/Contents/Resources/main-mac.icns')
    if icon.exists():
        shutil.copy2(icon, contents/'Resources/SoloStudio.icns')
        plist['CFBundleIconFile'] = 'SoloStudio'
    (contents/'Info.plist').write_bytes(plistlib.dumps(plist))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)], check=True)
    shutil.copytree(bundle, output)
print('Created ' + str(output))
