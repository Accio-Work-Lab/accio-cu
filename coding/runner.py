#!/usr/bin/env python3
from pathlib import Path
import sys


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from accio_cu_code.cli import main


if __name__ == "__main__":
    sys.exit(main())
