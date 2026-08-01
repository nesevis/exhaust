# Exhaust macro implementation

This package contains the compiler-plugin implementation used by
[Exhaust](https://github.com/nesevis/exhaust).

The package is developed inside the Exhaust repository and published to a
separate repository by Exhaust's release workflow. The separate package keeps
the host-built macro plugin in a different Xcode package project from
Exhaust's destination-built library targets.

Do not make independent changes in the generated mirror repository. Changes
belong in `Packages/exhaust-macros` in the Exhaust repository.
