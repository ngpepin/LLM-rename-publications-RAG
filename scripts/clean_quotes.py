#!/usr/bin/env python3
"""Clean and convert straight quotes/apostrophes from stdin and write to stdout.

Replaces:
- double-quoted phrases -> “…”
- remaining double quotes -> ”
- single-quoted phrases -> ‘…’
- apostrophes between word characters -> ’
- removes C0 control characters
"""
import sys
import re


def main():
    try:
        s = sys.stdin.read()
        s = re.sub(r'"([^"]+)"', r'“\1”', s)
        s = s.replace('"', '”')
        s = re.sub(r"'([^']+)'", r"‘\1’", s)
        s = re.sub(r"(\w)'(\w)", r'\1’\2', s)
        # removes C0 control characters but keeps common whitespace like \n, \r, \t
        s = ''.join(ch if ord(ch) >= 32 or ch in '\n\r\t' else ' ' for ch in s)
        sys.stdout.write(s)
    except Exception as e:
        sys.stderr.write(str(e))
        sys.exit(1)


if __name__ == '__main__':
    main()
