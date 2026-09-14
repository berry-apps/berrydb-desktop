# Security Policy

BerryDB takes the security and privacy of user data and database credentials seriously. Because BerryDB connects to production and development databases, protecting credentials and preventing data leakage is a core design requirement.

---

## Supported Versions

Only the latest release of BerryDB receives security patches and updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## Reporting a Vulnerability

If you discover a security vulnerability or security-sensitive issue within BerryDB, **please do not disclose it publicly** via public GitHub issues, discussions, or social media.

Instead, please report vulnerabilities responsibly through one of the following channels:

1. **GitHub Security Advisory (Preferred)**:
   Navigate to the [Security tab](https://github.com/berry-apps/berrydb-desktop/security/advisories/new) of this repository and click **"Report a vulnerability"** (Private Vulnerability Reporting).
2. **Email**:
   Contact the core maintainers directly at `security@berryhub.app`.

### What to Include in Your Report

To help us triage and resolve the issue quickly, please provide:
- A clear description of the vulnerability.
- Step-by-step instructions or a minimal Proof of Concept (PoC) to reproduce the behavior.
- The affected component (e.g. Keychain storage, SSH tunnel, specific database driver).
- Potential impact and severity assessment.

### Our Commitment

- We will acknowledge receipt of your vulnerability report within **48 hours**.
- We will provide a timeline for assessing and remediating the issue.
- Once fixed, we will credit responsible reporters in release notes (unless anonymity is requested).
