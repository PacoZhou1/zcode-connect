#!/usr/bin/env python3
"""Test the three menu metadata actions using the shared real-AppStore harness."""
from pathlib import Path
import os
import sys

runner = Path(__file__).with_name("run-outbox-tests.py")
os.execv(sys.executable, [sys.executable, str(runner), "--suite", "metadata-actions", *sys.argv[1:]])
