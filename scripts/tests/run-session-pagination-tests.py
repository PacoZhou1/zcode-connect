#!/usr/bin/env python3
"""Run the real AppStore pagination suite with the shared, isolated state harness."""
from pathlib import Path
import os
import sys

runner = Path(__file__).with_name("run-outbox-tests.py")
os.execv(sys.executable, [sys.executable, str(runner), "--suite", "session-pagination"])
