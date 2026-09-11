# The test signing key

`checks.<system>.mobile-catalog` publishes signed `.lgx` packages, because the
publisher has no unsigned path — `mkPackage` signs and then `lgx verify`s every
package it produces, precisely so the path the tests exercise is the path a
release takes.

`nix-bundle-lgx-test.{jwk,pub,did}` is the key those fixture packages are
signed with.

**It is a test key and its secret half is in this repository.** A signature by
it proves only that the test ran. Nothing here ever adds it to a keyring, and
no published package is signed with it. A real catalog release is signed by a
key that is not in a git repo; the only thing a build points at is the DID,
which is data.

It is committed rather than generated per run so the DID is known at
evaluation time: `mkCatalog` takes the signer DIDs as an argument, and a key
minted inside a derivation could only be checked after the fact.

Regenerate with:

```bash
lgx keygen --name nix-bundle-lgx-test --output-dir tests/keys
```
