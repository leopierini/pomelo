import Foundation
import PomeloCore

extension CombineInputError {
    /// Names `input` as the cause of a failure in `body`, for a combining engine's work on one input. A cancellation
    /// passes through unwrapped (the runner only recognises a bare `CancellationError`), and an input already named
    /// keeps its name.
    static func blaming<T>(_ input: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let named as CombineInputError {
            throw named
        } catch {
            throw CombineInputError(input: input, underlying: error)
        }
    }
}
