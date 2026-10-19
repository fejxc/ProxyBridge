#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -o build/relay-harness -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  ProxyBridge/Models/*.swift ProxyBridge/Presentation/L10n.swift ProxyBridge/Services/TCPRelay.swift tools/relay/RelayHarness.swift
python3 tools/relay/test_relay.py
