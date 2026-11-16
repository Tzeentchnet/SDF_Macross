"""Tests for the standalone project tools."""

import sys
from pathlib import Path

TOOLS = str(Path(__file__).resolve().parents[1] / "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
