---
name: guix-configs
description: Work in the guix-configs repository using its pinned Guix channels, repository layers, and verification commands.
---

# guix-configs

Use this skill when changing the `guix-configs` repository.

## Ground rules

1. Read `AGENTS.md` and the relevant page under `docs/` before editing.
2. Use the pinned channels; never run `guix pull` or select `@latest`:

   ```sh
   guix time-machine -C channels.lock.scm -- ...
   ```

3. Keep secrets out of the repository. Only age ciphertext may be committed;
   never copy plaintext keys, tokens, or credentials into configs or docs.
4. Keep application ownership explicit. Shared targets belong to one owner;
   other applications consume them through the documented service.
5. Prefer declarative Guix mechanisms over activation scripts or manual copies.

## Verification

Run the narrowest checks first, then the standard suites:

```sh
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
guix time-machine -C channels.lock.scm -- repl -- tests/run-tests.scm --apps
```