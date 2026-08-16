# AGENTS_OVERRIDE.md

This project's answers to the choices the universal agent rules deliberately
leave open, plus every deliberate departure from them.

Universal rules live in `~/projects/Agents` (see `AGENTS.md` for the clone
URL). Every project-local document already takes priority over shared rules;
this file keeps declarations and explicit overrides easy to find.

---

## Declarations

### Minimum Perl version

> **Minimum: 5.10.0**

`dist.ini` declares `perl = 5.010000`. Shipped modules use `use strict` and
`use warnings` rather than a version pragma.

Reason: this is a released distribution with a long-standing compatibility
promise and active CPAN Testers coverage on old perls. Raising the floor is a
release decision, not a cleanup.

### Subroutine signatures

> **Policy: disabled**

> **Enabling pragma: not applicable**

Argument handling follows the surrounding code using `@_`.

Reason: the declared floor is 5.10, which cannot express signatures at all.

### POD placement

> **Layout: all at bottom (default)**

One continuous POD document under `__END__`.

Reason: matches every module already in `lib/`.

### Test layout and provenance

> **Scheme: neither shared scheme — legacy layout, frozen**

`t/` holds `unit/` and `integration/` subtrees plus loose `.t` files at its
root; `t2/` is a second suite with its own `lib/`. There are no
`# Test origin:` headers and no `t/AI/` tree.

> **Layout audit: not run — `agent_scripts/audit-test-layout` is not copied
> into this project.**

Reason: the layout predates the shared schemes and the suite is large. New
tests go beside the existing tests they relate to. See the override below.

### perltidy

> **Config: shared**

`.perltidyrc` at the project root is byte-identical to
`~/projects/Agents/templates/perltidyrc`.

Reason: no reason to differ.

---

## Overrides

### Object base class

Universal: `Object::HashBase` for objects.
Here: the in-tree `Test2::Harness::Util::HashBase`.
Reason: the harness bundles its own copy so it has no external object
dependency. Swapping it for the CPAN module would add a prerequisite to a
distribution whose whole job is to run before the rest of the toolchain is
trusted.

### Test layout

Universal: category directories plus `# Test origin:` headers for new
projects, or a `t/AI/` mirror tree.
Here: neither. The existing layout is frozen.
Reason: a released distribution with a large suite; reorganizing `t/` would
churn every file for no shipped benefit and would break the `.yath.rc`
`--default-search glob(t/*)` setting and the integration fixtures that
reference their own paths.

---

## Prior rulings

Recorded in `RULINGS.md`, not here. This file holds declarations and
shared-rule overrides; a ruling is neither.
