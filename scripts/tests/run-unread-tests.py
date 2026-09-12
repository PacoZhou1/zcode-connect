#!/usr/bin/env python3
"""Run the bounded unread/CAS suite using the shared real-AppStore state harness."""
from pathlib import Path
import os
import sys

runner = Path(__file__).with_name("run-outbox-tests.py")
os.execv(sys.executable, [sys.executable, str(runner), "--suite", "unread"])
