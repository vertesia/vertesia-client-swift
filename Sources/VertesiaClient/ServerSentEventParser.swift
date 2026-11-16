#if canImport(Darwin)
struct ServerSentEventParser {
    struct Event {
        let name: String
        let id: String?
        let data: String
    }

    private(set) var retry: Duration?
    private var lineBytes: [UInt8] = []
    private var isFirstLine = true
    private var wasCarriageReturn = false
    private var name = ""
    private var id: String?
    private var data: [String] = []

    mutating func consume(_ byte: UInt8) -> Event? {
        let followsCarriageReturn = wasCarriageReturn
        wasCarriageReturn = byte == 13
        if byte == 10 && followsCarriageReturn { return nil }
        guard byte == 10 || byte == 13 else {
            lineBytes.append(byte)
            return nil
        }

        var line = String(decoding: lineBytes, as: UTF8.self)[...]
        lineBytes.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }
        if line.isEmpty {
            defer {
                name = ""
                id = nil
                data.removeAll(keepingCapacity: true)
            }
            guard !data.isEmpty else { return nil }
            return Event(name: name.isEmpty ? "message" : name, id: id, data: data.joined(separator: "\n"))
        }

        let fields = line.utf8.split(separator: 58, maxSplits: 1, omittingEmptySubsequences: false)
        var value = fields.count == 2 ? fields[1] : line.utf8.suffix(0)
        if value.first == 32 { value = value.dropFirst() }
        switch String(decoding: fields[0], as: UTF8.self) {
        case "event": name = String(decoding: value, as: UTF8.self)
        case "data": data.append(String(decoding: value, as: UTF8.self))
        case "id":
            if !value.contains(0) { id = String(decoding: value, as: UTF8.self) }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ (48...57).contains($0) }) {
                retry = .milliseconds(min(Int(String(decoding: value, as: UTF8.self)) ?? 30_000, 30_000))
            }
        default: break
        }
        return nil
    }
}
#endif
