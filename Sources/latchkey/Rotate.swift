import AppKit
import Foundation
import LatchkeyCore

// `latchkey touched` and `latchkey rotate`: find the keys a session was given, and replace them.

/// Items released by Latchkey (to commands, agents, grants) in a window, from the access log.
struct Touched {
    var id: String
    var times: Int
    var last: Date
    var by: Set<String>
}

/// What the access log says was released since `since`, optionally only to callers whose chain includes `by`, or
/// only under grant `grant`.
func touchedItems(since: Date, by: String?, grant: String?) -> [Touched] {
    var out: [String: Touched] = [:]
    for e in Broker.readLog(limit: .max) where e.op == "get" && e.time >= since {
        guard e.decision.hasPrefix("allowed") || e.decision.hasPrefix("approved") else { continue }
        if let by, !e.chain.contains(where: { $0.lowercased() == by.lowercased() }) { continue }
        if let grant, !e.decision.contains("grant \(grant)") { continue }
        for id in e.names {
            var t = out[id] ?? Touched(id: id, times: 0, last: e.time, by: [])
            t.times += 1
            t.last = max(t.last, e.time)
            t.by.insert(e.chain.prefix(3).joined(separator: " › "))
            out[id] = t
        }
    }
    return out.values.sorted { $0.id < $1.id }
}

/// Options shared by `touched` and `rotate --touched`.
func touchedFilter(_ rest: inout [String]) -> (since: Date, by: String?, grant: String?) {
    var since = Date().addingTimeInterval(-86400), by: String?, grant: String?
    var kept: [String] = []
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--since":
            guard !rest.isEmpty, let d = GrantStore.parseDuration(rest.removeFirst()) else { fail("--since takes a time such as 4h or 2d", code: 64) }
            since = Date().addingTimeInterval(-d)
        case "--by":
            guard !rest.isEmpty else { fail("--by takes a program name, such as claude", code: 64) }
            by = rest.removeFirst()
        case "--grant":
            guard !rest.isEmpty else { fail("--grant takes a grant id", code: 64) }
            grant = rest.removeFirst()
        default: kept.append(a)
        }
    }
    rest = kept
    return (since, by, grant)
}

func touchedCommand(_ input: [String]) -> Never {
    var rest = input
    let f = touchedFilter(&rest)
    let json = rest.contains("--json")
    if let other = rest.first(where: { $0 != "--json" }) { fail("unknown option \(other)", code: 64) }
    let items = touchedItems(since: f.since, by: f.by, grant: f.grant)
    if json {
        let rows = items.map { ["id": $0.id, "times": String($0.times), "last": ISO8601DateFormatter().string(from: $0.last),
                                "by": $0.by.sorted().joined(separator: "; ")] }
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    guard !items.isEmpty else { print("Nothing was released in that time."); exit(0) }
    for t in items {
        print("\(t.id)  \(t.times)×, last \(t.last.formatted(date: .abbreviated, time: .shortened))  (\(t.by.sorted().joined(separator: "; ")))")
    }
    print("\nReplace them with: latchkey rotate --touched\(f.by.map { " --by \($0)" } ?? "")\(f.grant.map { " --grant \($0)" } ?? "")")
    exit(0)
}

/// Guided rotation: for each item, where to make a new key, then the new value saved (the old one stays in history),
/// then the environments it's linked to pushed if asked. Grants that cover the items are ended first, so nothing
/// keeps reading the old value without asking.
func rotateCommand(_ input: [String]) -> Never {
    var rest = input
    var open = false, push = false, fromTouched = false
    let f = touchedFilter(&rest)
    var words: [String] = []
    for a in rest {
        switch a {
        case "--open": open = true
        case "--push": push = true
        case "--touched": fromTouched = true
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)", code: 64) }
            words.append(a)
        }
    }
    var ids = words.isEmpty ? [] : expandIDs(words)
    if fromTouched { ids += touchedItems(since: f.since, by: f.by, grant: f.grant).map(\.id) }
    let all = Dictionary(uniqueKeysWithValues: (send(Request(op: "list")).secrets ?? []).map { ($0.name, $0) })
    ids = Array(Set(ids)).filter { all[$0] != nil }.sorted()
    guard !ids.isEmpty else { fail(fromTouched ? "nothing was released in that time" : "usage: latchkey rotate IDS|PATTERN... | --touched [--since 24h] [--by NAME] [--grant ID] [--open] [--push]", code: fromTouched ? 0 : 64) }
    if isatty(STDIN_FILENO) != 1 && ids.count > 1 { fail("rotating several items needs a terminal, to ask for each new value", code: 64) }

    // End grants that would keep handing out these items.
    let covering = (send(Request(op: "grants")).grants ?? []).filter { g in ids.contains { id in g.names.contains { Grant.entry($0, matches: id) } } }
    for g in covering { _ = send(Request(op: "revoke", names: [g.id])); print("ended grant \(g.id) (\(g.names.joined(separator: ", ")))") }

    var rotated: [String] = []
    for (n, id) in ids.enumerated() {
        let info = all[id]!
        let service = info.service ?? "its service"
        print("\n[\(n + 1)/\(ids.count)] \(id)  (\(service))")
        if let page = info.service.flatMap({ Services.keyPages[$0] }) {
            print("  Make a new key at \(page), then revoke the old one there.")
            if open, let url = URL(string: page) { NSWorkspace.shared.open(url) }
        } else {
            print("  Make a new value at \(service), then revoke the old one there.")
        }
        let value = readValue(prompt: "  New value (leave empty to skip): ")
        if value.isEmpty { print("  skipped"); continue }
        _ = send(Request(op: "set", names: [id], value: value))
        rotated.append(id)
        print("  saved; the old value is in its history")
    }
    guard !rotated.isEmpty else { exit(0) }

    // Environments with remote links that hold the rotated items.
    let byScope = Dictionary(grouping: rotated.filter { !(ItemID($0)?.isShared ?? true) }) { id -> String in
        let r = ItemID(id)!; return "\(r.project)/\(r.environment)"
    }
    for (scope, items) in byScope.sorted(by: { $0.key < $1.key }) {
        guard !(send(Request(op: "links", names: [scope])).links ?? []).isEmpty else { continue }
        if push {
            let r: Response
            do { r = try call(Request(op: "push", names: [scope], only: items)) } catch { failRun(error) }
            for p in r.pushResults ?? [] { print("\(p.ok ? "pushed" : "FAILED") \(ItemID(p.item)?.name ?? p.item) → \(p.link)\(p.error.map { "  \($0)" } ?? "")") }
            if !r.ok { print("push to \(scope) didn't finish: \(r.error ?? "not approved")") }
        } else {
            print("\(scope) is linked elsewhere; push the new values: latchkey push \(scope) --only \(items.joined(separator: ","))")
        }
    }
    exit(0)
}
