#!/usr/bin/env python3
"""Mythix System Manager — GTK3 system manager for Linux Mint and Debian.
Thin launcher; the app lives in the system_manager package."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from system_manager.app import main

if __name__ == "__main__":
    main()
