<!-- Thanks for sending a PR. A few quick checks below — the more boxes checked, the faster this can land. -->

## What this changes

<!-- One or two sentences. What and why. -->

## Why

<!-- The motivating problem, bug, or use case. Link to an issue if there is one. -->

## How to verify

<!-- Commands a reviewer can run locally to see the change work. -->

```bash
make check
# plus anything else specific to this change
```

## Checklist

- [ ] `make check` passes (lint + smoke tests)
- [ ] `pager doctor` still green after the change (if install/runtime is touched)
- [ ] CHANGELOG `[Unreleased]` updated if user-visible
- [ ] No new dependencies added without discussion
- [ ] Commit message follows the repo style (imperative, short subject, body explains *why*)
