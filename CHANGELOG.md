# Changelog

## 1.0.0 - 2026-11-04

- Initial public release.
- Audit per-address IPv6 egress, default source selection and duplicate routes.
- Detect ifupdown `inet6 auto` and `inet6 static` repair modes.
- Refuse automatic changes for `manual`, `dhcp`, tunnel and unknown methods.
- Require the VPS-specific control-panel IPv6 before any repair.
- Prevent dhcpcd `slaac private` from conflicting with the provider address.
- Apply mode-specific kernel RA/SLAAC settings without rewriting addresses.
- Back up configuration and require post-reboot verification.
