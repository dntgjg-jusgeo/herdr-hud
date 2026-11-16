import Foundation
import ImageIO

/// Browser bytes are untrusted; validate independently before any upload.
struct ImageAttachment {
    static let maximumBytes = 4 * 1024 * 1024
    static let maximumCount = 3
    let data: Data, name: String
    static func parse(_ value: Any?) throws -> [ImageAttachment] {
        guard let value else { return [] }
        guard let rows = value as? [Row], rows.count <= maximumCount else { throw HUDError("Attach up to 3 raster images, 4 MB each.") }
        return try rows.map { row in
            guard let base64 = row["data"] as? String, base64.utf8.count <= ((maximumBytes + 2) / 3) * 4,
                  let bytes = Data(base64Encoded:base64), !bytes.isEmpty, bytes.count <= maximumBytes,
                  let source = CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let type = CGImageSourceGetType(source) as String?,
                  let ext = ["public.png":"png","public.jpeg":"jpg","org.webmproject.webp":"webp","com.compuserve.gif":"gif"][type],
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 40_000_000,
                  CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:320] as CFDictionary) != nil else {
                throw HUDError("Use valid PNG, JPEG, WebP or GIF images, up to 4 MB and 40 million pixels each.")
            }
            return ImageAttachment(data:bytes,name:"hud-image-" + UUID().uuidString + "." + ext)
        }
    }
}
