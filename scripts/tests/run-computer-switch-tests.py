#!/usr/bin/env python3
"""Run the five bounded computer-selection scenarios; no real I/O or UIKit."""
from pathlib import Path
import os
import sys

runner = Path(__file__).with_name("run-outbox-tests.py")
os.execv(sys.executable, [sys.executable, str(runner), "--suite", "computer-switch"])
