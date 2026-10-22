# Experiments

Real-machine experiments that decide defaults. Each section records the exact command, the raw observations
and the decision. Outputs are redacted (emails → `<email>`, UUIDs → `<uuid>`). Experiments about features that
were later removed are not kept here.

## E2 — Does `codesign` accept an untrusted self-signed identity from a temporary keychain?

**Date:** 2026-09-24 (≈02:02 UTC). **System:** macOS 27.0 (26A428), `/usr/bin/codesign`, OpenSSL 3.6.3 (Homebrew).

### Question

Can the builder sign clones with a self-signed code-signing certificate that lives only in a keychain file
passed via `codesign --keychain`, without trusting the certificate, without importing anything into the login
keychain and without touching the keychain search list (constraints G3, G4, G10)?

### Command

```bash
KC="$SCRATCH/cmacc-test.keychain-db"; SHA=$(scripts/make-test-identity.sh "$KC")
printf 'int main(){return 0;}' > "$SCRATCH/hello.c" && clang -o "$SCRATCH/hello" "$SCRATCH/hello.c"
codesign --force --timestamp=none --sign "$SHA" --keychain "$KC" "$SCRATCH/hello"; echo "sign=$?"
codesign -dv --verbose=2 "$SCRATCH/hello" 2>&1 | grep -E 'Authority|Identifier'
codesign --verify --strict --verbose=2 "$SCRATCH/hello"; echo "verify=$?"
codesign -d -r- "$SCRATCH/hello" 2>&1 | grep designated
security find-identity -v -p codesigning "$KC"
security delete-keychain "$KC"
```

### Observations

| Item | Result |
|------|--------|
| `make-test-identity.sh` | exit 0, printed the SHA-1 (`9C85C080…2747`) |
| User search list before / after creation / after deletion | only `login.keychain-db` each time (unchanged) |
| `codesign --sign <sha1> --keychain <temp>` | `sign=0` |
| Signature details | `Identifier=hello`, `Authority=ClaudeMultiAcc Test Signing`, `TeamIdentifier=not set` |
| `codesign --verify --strict` | `valid on disk`, `satisfies its Designated Requirement`, exit 0 |
| Designated requirement | `identifier hello and certificate leaf = H"9c85c080…2747"` |
| `security find-identity -v -p codesigning <temp>` | `0 valid identities found` (the certificate is untrusted) |
| `security delete-keychain <temp>` | exit 0; search list still only the login keychain |

### Decision

`codesign` signs with the untrusted self-signed identity when it is addressed by SHA-1 and its keychain is passed
with `--keychain`; `find-identity -v` calling it "not valid" does not matter for signing. No trust settings were
changed. The designated requirement pins the leaf certificate hash, so a **permanent** identity keeps a clone's
requirement stable across rebuilds, while ad hoc signatures only get an implicit cdhash requirement
(`# designated => cdhash H"…"`) that changes with every build. The Task 6 e2e therefore ran with the temp-keychain
identity (not `--identity adhoc`): the staged `stagetest` clone verified with `Authority=ClaudeMultiAcc Test Signing`
and `designated => identifier "com.imaxzone.claude.stagetest" and certificate leaf = H"…"`, and was then discarded
together with the temp keychain.

This is also why the app creates its permanent identity itself, the same way, in a keychain file of its own
(`SigningIdentityProvisioner`); `scripts/signing-setup.sh` is the older, optional way that imports it into the login
keychain.
