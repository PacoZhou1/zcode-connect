#!/usr/bin/env python3
"""Run computer selection and persistent first-connection gates; no services or UIKit."""
from pathlib import Path
import os
import sys

runner = Path(__file__).with_name("run-outbox-tests.py")
os.execv(sys.executable, [sys.executable, str(runner), "--suite", "computer-switch"])
