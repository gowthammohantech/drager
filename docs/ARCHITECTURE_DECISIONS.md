# Architecture Decisions

Index of ADRs. Each file in `docs/ADR/` has context, decision and consequences.

| ADR | Title | Status |
|---|---|---|
| [ADR-001](ADR/ADR-001.md) | Network.framework as the primary transport | Accepted |
| [ADR-002](ADR/ADR-002.md) | Bonjour for discovery, cryptography for identity | Accepted |
| [ADR-003](ADR/ADR-003.md) | Separate control DTOs from the binary data plane | Accepted |
| [ADR-004](ADR/ADR-004.md) | Manual spatial calibration | Accepted |
| [ADR-005](ADR/ADR-005.md) | User-selected destination with security-scoped bookmark | Accepted |
| [ADR-006](ADR/ADR-006.md) | Native SwiftUI + AppKit, one SPM package with many targets | Accepted |
| [ADR-007](ADR/ADR-007.md) | One concurrent transfer, bounded backpressure | Accepted |
| [ADR-008](ADR/ADR-008.md) | Overlay is a best-effort visual layer | Accepted |
| [ADR-009](ADR/ADR-009.md) | Environment decisions taken autonomously | Accepted |
| [ADR-010](ADR/ADR-010.md) | Pairing: SAS-authenticated X25519, sessions over TLS 1.3 external PSK | Accepted |
| [ADR-011](ADR/ADR-011.md) | Interrupted transfers restart; resume is P1 | Accepted |
| [ADR-012](ADR/ADR-012.md) | Hand-written Xcode projects, no generator | Accepted |

Requirement precedence for conflicts: Apple security/API restrictions > BRD > FRD > PRD > TD/AD.
