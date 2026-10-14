# 0003 MSE/PE (BEP 8) implemented in pure Swift

## Context
Many peers require Message Stream Encryption. CryptoKit has no Diffie-Hellman over a custom group and no RC4.

## Decision
`MSECrypto.swift` in Core: DH over MSE's fixed 768-bit prime with a small `BigUInt` modexp, plus RC4; SHA-1 from CryptoKit. `crypto_provide` advertises RC4 only. The handshake is attempted first, with a plaintext reconnect fallback (`EncryptionPolicy`).

## Consequences
- No third-party dependency.
- A modexp costs ~4 ms in Release, acceptable per connection.
- Tests that need deterministic timing pin `.plaintextOnly`.
