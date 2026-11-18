import Foundation

enum Hex {
    /// Lowercase, two digits per byte.
    static func string(_ bytes: some Sequence<UInt8>) -> String {
        bytes.reduce(into: "") { result, byte in
            if byte < 0x10 {
                result.append("0")
            }
            result.append(String(byte, radix: 16))
        }
    }
}
