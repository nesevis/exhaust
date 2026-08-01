# Exhaust macro implementation

This repository contains the compiler-plugin implementation used by
[Exhaust](https://github.com/nesevis/exhaust). It is a generated release
mirror: Exhaust remains the source repository, and its release workflow
publishes this package automatically.

Most users should depend only on **Exhaust**. Do not add `exhaust-macros`
directly to an application or library.

## Why this is a separate package

Exhaust originally kept its `ExhaustMacros` target in the same Swift package
as its runtime libraries. That is a valid Swift Package Manager layout, and
the compiler successfully built the package, expanded its macros, and
preserved its documentation.

In Xcode, however, that layout caused Quick Help to display **No Quick Help**
for Exhaust symbols in consuming projects. The problem occurred whether
`ExhaustCore` was built from source or distributed as an XCFramework.
Documentation was still present in the compiled Swift modules, symbol graphs,
and SourceKit responses; code completion could display it even while the Quick
Help inspector remained empty.

The failure was isolated to Xcode's generated workspace and index ownership
when one package project owned both:

- the host-built compiler-plugin target; and
- the destination-built Exhaust library targets.

Separating the macro implementation into another Swift package gives the
compiler plugin its own generated package project. In consumer experiments,
that package boundary restored Quick Help without changing Exhaust's
documentation or macro implementation. This repository exists to preserve
that working topology for released consumers.

## Contributing

Please open issues, discussions, and pull requests in
[nesevis/exhaust](https://github.com/nesevis/exhaust). Changes to the macro
implementation belong in its `Packages/exhaust-macros` directory and reach
this repository through the normal Exhaust release process.
