#!/usr/bin/env python3
"""Run persisted fork-command and connection-isolation cases in the AppStore harness."""
from pathlib import Path
import os
import sys

runner = Path(__file__).with_name("run-outbox-tests.py")
os.execv(sys.executable, [sys.executable, str(runner), "--suite", "fork"])
