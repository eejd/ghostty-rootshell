import Cocoa

/// A wrapper that allows a Swift Codable to implement NSSecureCoding.
class CodableBridge<Wrapped: Codable>: NSObject, NSSecureCoding {
    let value: Wrapped
    init(_ value: Wrapped) { self.value = value }
    
    static var supportsSecureCoding: Bool { return true }
    
    required init?(coder aDecoder: NSCoder) {
        // TODO: This outputs a warning with deprecation on decode. I don't know how to
        // fix that yet but there must be something we can change with the encode/decode here
        // to resolve it.
        guard let data = aDecoder.decodeData() else { return nil }
        guard let archiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        guard let value = archiver.decodeDecodable(Wrapped.self, forKey: "value") else { return nil }
        self.value = value
    }
    
    func encode(with aCoder: NSCoder) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        try? archiver.encodeEncodable(value, forKey: "value")
        aCoder.encode(archiver.encodedData)
    }
}
