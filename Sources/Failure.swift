import Foundation

struct SwitchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
