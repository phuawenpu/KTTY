# KTTY - Secure Mobile Terminal Relay

## Overview
KTTY is a highly secure, resilient, fixed-proportion mobile terminal emulator built with Flutter. It is designed to interface with a remote Golang host agent via an untrusted cloud relay. The application provides a full programmer's environment on mobile devices, completely bypassing native OS keyboards and orientation restrictions to provide a desktop-grade terminal experience.

## Core Features
* **Zero-Trust Architecture:** End-to-End Encryption (XChaCha20-Poly1305) and Post-Quantum Key Exchange (ML-KEM/Kyber) ensure the cloud relay cannot intercept, tamper with, or read terminal data.
* **Custom Programmer Keyboard:** A gesture-based, multi-layered custom keyboard optimized for terminal input. It features a persistent control cluster (`Ctrl`, `Tab`, `Esc`, Arrows) and uses swipe gestures to access numeric and extended symbol layers.
* **Resilient State Management:** Built to survive mobile network drops. Features include sequence tracking, visual liveliness indicators (Green/Yellow/Red), and defensive UI locks that disable the keyboard during sync phases to prevent blind input.
* **Strict Display Modes:** * **Portrait (Interactive):** A 65/35 vertical split between the terminal emulator (`xterm`) and the custom keyboard.
  * **Landscape (Read-Only):** Forces 100% terminal width for reading wide log files, completely hiding the keyboard and preventing text input.

## Local Development & Setup

KTTY is designed to be developed entirely independently of the Golang backend. You can build the UI and test terminal emulation by standing up a local Mock WebSocket server that adheres to the established Interface Contract.

### Prerequisites
* [Flutter SDK](https://flutter.dev/docs/get-started/install) (Stable Channel)
* Dart 3.x

### Getting Started
1. Clone the repository:
   ```bash
   git clone <repository_url>
   cd ktty
   ```
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the application:
   ```bash
   flutter run
   ```

## The Interface Contract (API Boundary)
If you are building a local mock server for testing, KTTY communicates exclusively via WebSockets using the following unencrypted routing and encrypted data envelopes. 

**1. Room Join (Unencrypted)**
```json
{"action": "join", "room_id": "<SHA-256 Hash of PIN>"}
```

**2. Standard Data Stream (Encrypted Envelope)**
All terminal I/O and system commands use this structure. The `payload` must be decrypted using the negotiated XChaCha20 key.
```json
{
  "seq": 402,
  "type": "pty", 
  "payload": "<Base64 Encoded XChaCha20 Ciphertext>"
}
```

*For complete details on the ML-KEM handshake, Out-of-Band (OOB) command types, and sequence recovery limits, please refer to the primary KTTY Engineering Specification document.*
