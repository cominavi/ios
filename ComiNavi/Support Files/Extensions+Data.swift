//
//  Extensions+Data.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import CryptoKit
import Foundation

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

extension URL {
    func md5Digest() -> Data? {
        let bufferSize = 16 * 1024

        do {
            // Open file for reading:
            let file = try FileHandle(forReadingFrom: self)
            defer {
                file.closeFile()
            }

            // Create and initialize MD5 context:
            var md5 = CryptoKit.Insecure.MD5()

            // Read up to `bufferSize` bytes, until EOF is reached, and update MD5 context:
            while autoreleasepool(invoking: {
                let data = file.readData(ofLength: bufferSize)
                if data.count > 0 {
                    md5.update(data: data)
                    return true // Continue
                } else {
                    return false // End of file
                }
            }) {}

            // Compute the MD5 digest:
            return Data(md5.finalize())
        } catch {
            NSLog("Error: \(error)")

            return nil
        }
    }
}
