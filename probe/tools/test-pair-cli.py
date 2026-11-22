#!/usr/bin/env python3
"""Pairing CLI public-key normalization, without network or terminal access."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
from unittest import mock

path = Path(__file__).with_name("npulse-cli.py")
spec = importlib.util.spec_from_file_location("pair_cli", path)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)

for command in ("pair", "pair-relay"):
    args = [str(path), command, "127.0.0.1:9527"]
    if command == "pair-relay": args += ["--token", "fixture-token", "--code", "ABCD-EFGH"]
    for public in ("ab" * 32, "AB" * 32, "aB" * 32, "", None):
        argv = args + (["--admin-pk", public] if public is not None else [])
        with mock.patch.object(sys, "argv", argv), mock.patch("builtins.input", side_effect=["y", "y"]), mock.patch.object(client, "PairClient") as factory:
            factory.return_value.art = "art"; factory.return_value.code = "123 456"
            factory.return_value.confirm.return_value = {"ok": True}
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()): client.main()
            factory.return_value.confirm.assert_called_once_with(True, admin_pk=public.lower() if public else None)
            factory.return_value.close.assert_called_once_with()
    for public in ("ab", "a" * 65, "G" * 64):
        with mock.patch.object(sys, "argv", args + ["--admin-pk", public]), mock.patch.object(client, "PairClient") as factory:
            with contextlib.redirect_stderr(io.StringIO()):
                try: client.main()
                except SystemExit as error: assert error.code == 2
                else: raise AssertionError("malformed public key accepted")
            factory.assert_not_called()
print("PASS direct/relay pairing CLI: uppercase/mixed-case admin keys sent lowercase; empty/omitted keys send null; malformed keys rejected before connection")
