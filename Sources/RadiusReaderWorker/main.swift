// SPDX-License-Identifier: MPL-2.0
import Foundation
import RadiusCore
import RadiusReaderLogic

let response: ReaderResponse
do {
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, ReaderRequest.maximumMessageBytes + 1 - input.count)), !chunk.isEmpty {
        input.append(chunk)
        guard input.count <= ReaderRequest.maximumMessageBytes else { throw ValidationError("Reader received too much page data.") }
    }
    let request = try JSONDecoder().decode(ReaderRequest.self, from: input)
    response = ReaderResponse(text: try ReaderExtraction.extract(request.html))
} catch { response = ReaderResponse(error: String(error.localizedDescription.prefix(500))) }
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
