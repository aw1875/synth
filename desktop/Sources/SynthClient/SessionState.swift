import SynthProtocol

public struct SessionState: Sendable {
    public private(set) var status: Synth.Status?
    public private(set) var messages: [Synth.Message] = []
    public private(set) var dropped: UInt64 = 0
    public private(set) var models: Synth.Models?
    public private(set) var notices: [String] = []
    public internal(set) var failure: String?
    private var streaming: Synth.Stream?

    public var stream: Synth.Stream? {
        guard let streaming, streaming.request == status?.request else { return nil }
        return streaming
    }

    mutating func replace(with snapshot: Synth.Snapshot) {
        status = snapshot.status
        messages = snapshot.messages
        dropped = snapshot.dropped
        streaming = snapshot.stream
        failure = nil
    }

    mutating func update(_ message: Synth.Message, appended: Bool) {
        if let index = messages.lastIndex(where: { $0.seq == message.seq }) {
            messages[index] = message
        } else if appended {
            messages.append(message)
        }
        if appended && message.role == "assistant" { streaming = nil }
    }

    mutating func append(_ delta: Synth.Stream) {
        if streaming?.request != delta.request {
            streaming = delta
        } else {
            streaming?.text += delta.text
            streaming?.thinking += delta.thinking
            if delta.closed { streaming?.closed = true }
        }
    }

    mutating func update(_ status: Synth.Status) {
        self.status = status
        if streaming?.request != status.request { streaming = nil }
    }

    mutating func update(_ models: Synth.Models) {
        self.models = models
    }

    mutating func notice(_ text: String) {
        notices.append(text)
        if notices.count > 50 { notices.removeFirst() }
    }

    mutating func disconnect(_ message: String?) {
        streaming = nil
        models = nil
        failure = message
    }
}
