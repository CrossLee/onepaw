# Vendored DMG layout dependencies

The release builder writes Finder's `.DS_Store` directly so macOS packaging is
deterministic and does not require GUI automation or accessibility permissions.
These pure-Python wheels are loaded in place; they are not installed globally.

- `ds_store` 1.3.1 — MIT, Python 3.7+, SHA-256 `fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5`
- `mac_alias` 2.2.2 — MIT, Python 3.7+, SHA-256 `504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd`

Each wheel contains its upstream license as `.dist-info/LICENSE`.
