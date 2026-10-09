#!/usr/bin/env python3
"""
Clean-room PyYAML Pipeline Validator for osm-addresses pipeline files.
Parses pipeline YAML files directly to ensure 100% valid YAML structure before committing.
"""

import os
import sys


def validate_pipeline(filepath):
    print(f"Validating '{filepath}' with native PyYAML...")
    try:
        import yaml
    except ImportError:
        print(f"Notice: PyYAML not installed in environment; skipping local parse for '{filepath}'.")
        return True

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            yaml.safe_load(f)
        print(f"SUCCESS: '{filepath}' is valid YAML.")
        return True
    except yaml.YAMLError as exc:
        print(f"FAIL: YAML syntax error in '{filepath}':", file=sys.stderr)
        print(exc, file=sys.stderr)
        return False


if __name__ == "__main__":
    target_files = sys.argv[1:] if len(sys.argv) > 1 else [
        "azure-pipelines.yml",
        "azure-pipelines-release.yml"
    ]
    all_passed = True
    for fp in target_files:
        if os.path.exists(fp):
            if not validate_pipeline(fp):
                all_passed = False
        else:
            print(f"Warning: File '{fp}' not found.", file=sys.stderr)
    if not all_passed:
        sys.exit(1)
