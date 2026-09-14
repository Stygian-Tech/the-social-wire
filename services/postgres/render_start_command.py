#!/usr/bin/env python3
"""Render the versioned adapter for Railway's managed-image start command."""
import pathlib
import shlex

script = pathlib.Path(__file__).with_name("railway-entrypoint.sh").read_text()
print("bash -c " + shlex.quote(script) + " -- postgres -p 5432 -c listen_addresses=* -c archive_mode=off -c archive_command= -c archive_library= -c restore_command=")
