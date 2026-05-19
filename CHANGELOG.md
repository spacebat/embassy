# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Embassy` supervisor and `child_spec/1` for consumer-tree mounting.
- `Embassy.Config` per-instance snapshot accessor backed by Registry meta.
- `Embassy.ReverseProxy` terminal plug supporting UDS and HTTP transports,
  with RFC 7230 hop-by-hop header handling and canonical X-Forwarded-*
  injection.
- `Embassy.BodyCache` `Plug.Parsers` `:body_reader` companion.
- `:telemetry` events: `[:embassy, :proxy, :start | :stop | :exception]`.
