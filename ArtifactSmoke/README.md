# ArtifactSmoke

A consumer of the ExhaustCore xcframework that lives outside the `exhaust` package boundary.

Every test target in this repository is part of the `exhaust` package, so under `EXHAUST_RELEASE=1` they compile against ExhaustCore's *package* interface. A real consumer compiles against the *public* interface. Mistakes that only that path exposes, such as a `package` type stored in a public struct, whose layout the consumer then computes wrongly, or a metadata accessor that is not exported, surface as heap corruption in the consumer and pass every in-package test.

`Scripts/verify-xcframework.sh` builds and runs this package in debug and release against `Frameworks/ExhaustCore.xcframework`. The release and xcframework-test workflows call it after the in-package artifact tests. The program runs failing properties through the public API, collects every `ExhaustReport` into an array, and copies them back out, which is the access pattern that crashed the 0.28.0 artifact.

Run it locally after `Scripts/build-xcframework.sh`:

```sh
bash Scripts/verify-xcframework.sh
```
