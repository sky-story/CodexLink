#!/usr/bin/env python3
"""Capture fictional data in a dedicated Simulator; never use a physical device or real pairing."""
import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit('Usage: capture-docs-ui.py DEDICATED_SIMULATOR_UUID')
simulator = sys.argv[1]
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
device = next((d for ds in devices['devices'].values() for d in ds if d['udid'] == simulator), None)
if not device or not device['name'].startswith('Codex Remote Docs'):
    raise SystemExit('Use a fresh dedicated simulator named Codex Remote Docs; existing test/user devices are refused.')
app = root / '.build/docs-ios/Build/Products/Debug-iphonesimulator/CodexMobile.app'
bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
out = root / 'docs/images'
raw = root / '.build/docs-ui-raw'
out.mkdir(parents=True, exist_ok=True)
raw.mkdir(parents=True, exist_ok=True)

def run(*args, **kwargs):
    return subprocess.run(['xcrun', 'simctl', *args], check=True, **kwargs)

run('install', simulator, str(app))
# Documentation needs neither camera nor microphone. Deny them only in this
# dedicated simulator so first-launch prompts cannot obscure the screenshots.
for service in ['camera', 'microphone']:
    run('privacy', simulator, 'revoke', service, bundle)
run('ui', simulator, 'appearance', 'light')
run('status_bar', simulator, 'override', '--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100')
font = ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', 32)
for scene in ['queue', 'approval', 'completed']:
    subprocess.run(['xcrun', 'simctl', 'terminate', simulator, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    env = {k: v for k, v in os.environ.items() if not k.startswith('SIMCTL_CHILD_CODEX_REMOTE_TEST_')}
    env['SIMCTL_CHILD_CODEX_REMOTE_DOCS_SCENE'] = scene
    run('launch', simulator, bundle, env=env)
    time.sleep(5)
    file = raw / f'{scene}.png'
    run('io', simulator, 'screenshot', str(file))
    source = Image.open(file).convert('RGB')
    # Add a label OUTSIDE the original screenshot; no actual UI is cropped or replaced.
    canvas = Image.new('RGB', (source.width, source.height + 84), '#eaf0f5')
    canvas.paste(source, (0, 84))
    draw = ImageDraw.Draw(canvas)
    draw.text((source.width / 2, 42), '演示数据 · 离线预览', font=font, fill='#34465a', anchor='mm')
    canvas.save(out / f'session-{scene}.png', optimize=True)
print('Saved three fictional-data UI screenshots. Review all images before publication.')
