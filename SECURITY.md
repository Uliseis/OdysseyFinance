# Security

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them privately through
[GitHub's private vulnerability reporting](https://github.com/Uliseis/OdysseyFinance/security/advisories/new).
You'll get a reply within a few days.

The same applies if you find anything in this repository or its history that looks like
real personal data (balances, transactions, account numbers, names) or a credential.

## How the app handles secrets and data

- **No server.** There is no backend holding user data or credentials.
- **Bank access keys** (the Enable Banking application key) and **broker API keys** live in the
  iCloud Keychain on the user's devices. They are never written to files, logged, or committed.
- **Financial data** is stored in an on-device SwiftData store and synced through the user's
  own *private* CloudKit database.
- **Face ID** locks the app whenever it goes to the background. Turning the lock off requires Face ID.
- **This repository contains code only.** Test fixtures and preview data are synthetic. Private
  keys must never be committed, not even throwaway test keys; tests that need one generate it at
  runtime.
