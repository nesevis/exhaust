// A child process that soaks the fixture's trap-bearing parser until it dies, so the parent test can
// inspect the breadcrumb and progress log the dead process left behind.
//
// The parent sets `TMPDIR` to a directory it controls, so the runtime's `$TMPDIR/exhaust/...` state
// lands where the parent can find it, and passes a sidecar path as the first argument. Just before
// the property feeds the runtime the input that will trip fault E, the probe writes that exact input
// to the sidecar — the last write before the process dies is the trapping input.

import Exhaust
import ExploreFixture
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ExploreTrapProbe <sidecar-path>\n".utf8))
    exit(2)
}

let sidecarURL = URL(fileURLWithPath: CommandLine.arguments[1])

let property: @Sendable (Message) -> Bool = { message in
    // Mirror fault E's gate so the sidecar captures precisely the input that is about to trap.
    if message.mode == .control,
       message.flags & 0b0001_0000 != 0,
       message.region == 7,
       message.payload.isEmpty == false
    {
        try? JSONEncoder().encode(message).write(to: sidecarURL)
    }
    do {
        _ = try Parser.decodeUnsafe(message)
        return true
    } catch {
        return false
    }
}

// A generous budget the probe never spends: fault E is roughly 1-in-75 by blind sampling, so the trap fires within milliseconds and kills the process well before this elapses.
_ = #explore(Fixture.messageGenerator, time: .seconds(120), property: property)

// Only reachable if the trap never fired — a failure of the fixture, not the runtime.
FileHandle.standardError.write(Data("ExploreTrapProbe completed without trapping\n".utf8))
exit(1)
