# \#gen

Build generators from primitives, structs, enums, and recursive types.

## Overview

`#gen` wraps generator expressions and enables dot-syntax for built-in factories. When multiple generators are combined with a trailing closure, the macro attempts to synthesise a bidirectional backward mapping from the closure body.

```swift
let gen = #gen(.int(in: 0...100))

let personGen = #gen(.string(length: 1...20), .int(in: 0...120)) { name, age in
    Person(name: name, age: age)
}
```

### Synthesising from Decodable types

`#gen` can also synthesise a generator from example JSON or a `Codable` instance, discovering the type's field structure automatically.

```swift
let gen = try #gen(Person.self, from: """
    {"name": "Alice", "age": 30, "active": true}
    """)

let gen = try #gen(from: existingInstance)
```

For the full guide, see <doc:BuildingGenerators>.
