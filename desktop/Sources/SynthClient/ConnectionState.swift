import Foundation
import SynthProtocol

extension SynthClient {
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case failed(String)
    }

    public enum Failure: LocalizedError {
        case disconnected
        case alreadyConnected
        case incompatible(acp: Int, synth: Int?)
        case invalidResponse(String)
        case handshakeTimedOut
        case invalidAnswer

        public var errorDescription: String? {
            switch self {
            case .disconnected: "Synth is disconnected."
            case .alreadyConnected: "Synth already has an open connection."
            case .incompatible(let acp, let synth):
                "Synth reports ACP \(acp) and extension \(synth.map(String.init) ?? "unavailable"). " +
                "Use an engine that supports ACP \(ACP.version) and Synth extension \(ACP.synthVersion)."
            case .invalidResponse(let reason): "Invalid response from Synth: \(reason)"
            case .handshakeTimedOut: "Synth did not respond to initialization."
            case .invalidAnswer: "This response does not match the pending interaction."
            }
        }
    }
}
