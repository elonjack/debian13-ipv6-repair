# Changelog

## 1.1.0 - 2026-11-04

- Render the interactive menu in yellow, with `NO_COLOR` support.
- Require an interactive TTY and handle end-of-input cleanly.
- Use iproute2 for strict, read-only IPv6 literal validation.
- Validate interface names before using them in sysctl keys or file paths.
- Create collision-resistant backup directories with restrictive permissions.
- Defer sysctl activation until reboot so repair does not change live SSH networking.
- Expand unit tests for invalid IPv6 input and interface-name validation.
- Add a one-line launcher that verifies the downloaded main script before execution.

## 1.0.0 - 2026-11-04

- Initial public release.
- Audit per-address IPv6 egress, default source selection and duplicate routes.
- Detect ifupdown `inet6 auto` and `inet6 static` repair modes.
- Refuse automatic changes for `manual`, `dhcp`, tunnel and unknown methods.
- Require the VPS-specific control-panel IPv6 before any repair.
- Prevent dhcpcd `slaac private` from conflicting with the provider address.
- Apply mode-specific kernel RA/SLAAC settings without rewriting addresses.
- Back up configuration and require post-reboot verification.
