import AVFoundation
import Foundation

enum DashHlsError: LocalizedError {
    case http(Int)
    case parse(String)
    case unsupportedAudio(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .parse(let message): return "parse: \(message)"
        case .unsupportedAudio(let codec): return "unsupported audio codec: \(codec)"
        }
    }

    var isAudioError: Bool {
        if case .unsupportedAudio = self { return true }
        return false
    }
}

/// Bilibili serves DASH as bare fMP4 (`.m4s`) files with separate video and
/// audio tracks. AVPlayer cannot open those directly, but it can play the very
/// same bytes when they are described by an fMP4 HLS playlist. This bridge
/// downloads the head of each track (ftyp+moov+sidx), builds an in-memory HLS
/// master/media playlist set whose segments point straight at the CDN via
/// byte ranges, and serves the playlists through AVAssetResourceLoader.
/// HDR10/HLG/Dolby Vision and Dolby (EC-3) audio metadata survive untouched,
/// so AVFoundation performs native HDR output.
final class DashHlsBridge: NSObject {
    static let scheme = "piliplushdr"

    private struct Segment {
        let offset: UInt64
        let size: UInt64
        let duration: Double
    }

    private struct Track {
        var url: String
        var isLocal: Bool
        var codec: String?
        var videoRange: String?  // "PQ" / "HLG"
        var initLength: UInt64 = 0
        var segments: [Segment] = []
        var totalDuration: Double = 0
        var totalSize: UInt64 = 0
        var fileLength: UInt64 = 0
        var isVideo: Bool
    }

    private let headers: [String: String]
    private var playlists: [String: Data] = [:]
    private var localFiles: [String: URL] = [:]  // loader path prefix -> file url
    private let loaderQueue = DispatchQueue(label: "piliplus.hdr.loader")

    init(headers: [String: String]) {
        self.headers = headers
        super.init()
    }

    var masterUrl: URL { URL(string: "\(Self.scheme)://bridge/master.m3u8")! }

    /// Builds all playlists. Throws DashHlsError; unsupportedAudio is reported
    /// separately so the Dart side can retry without the audio track.
    func prepare(videoUrl: String, audioUrl: String?, isFileSource: Bool, qualityCode: Int?) async throws {
        var video = try await loadTrack(url: videoUrl, isFileSource: isFileSource, isVideo: true)
        if video.videoRange == nil {
            // Bilibili quality 125 (HDR真彩) is HLG, 126 (Dolby Vision) is PQ.
            switch qualityCode {
            case 126: video.videoRange = "PQ"
            case 125: video.videoRange = "HLG"
            default: break
            }
        }

        var audio: Track? = nil
        if let audioUrl, !audioUrl.isEmpty {
            audio = try await loadTrack(url: audioUrl, isFileSource: isFileSource, isVideo: false)
            if let codec = audio?.codec, codec.hasPrefix("fLaC") || codec.hasPrefix("Opus") {
                throw DashHlsError.unsupportedAudio(codec)
            }
        }

        playlists["video.m3u8"] = mediaPlaylist(for: video, pathTag: "v")
        if let audio {
            playlists["audio.m3u8"] = mediaPlaylist(for: audio, pathTag: "a")
        }
        playlists["master.m3u8"] = masterPlaylist(video: video, audio: audio)
    }

    // MARK: - Track loading

    private func loadTrack(url: String, isFileSource: Bool, isVideo: Bool) async throws -> Track {
        var track = Track(url: url, isLocal: isFileSource, isVideo: isVideo)
        var data: Data
        if isFileSource {
            let fileUrl = URL(fileURLWithPath: url)
            let handle = try FileHandle(forReadingFrom: fileUrl)
            defer { try? handle.close() }
            track.fileLength = handle.seekToEndOfFile()
            handle.seek(toFileOffset: 0)
            data = handle.readData(ofLength: min(1 << 20, Int(track.fileLength)))
            localFiles[isVideo ? "v" : "a"] = fileUrl
        } else {
            let (head, total) = try await fetchRange(url: url, upTo: 1 << 20)
            data = head
            track.fileLength = total
        }

        // Walk the top level boxes: ftyp [free] moov [free] sidx moof...
        var cursor: UInt64 = 0
        var moovRange: Range<Int>?
        var sidxStart: UInt64?
        var sidxData: Data?
        while cursor + 16 <= UInt64(data.count) {
            let size32 = data.readU32(Int(cursor))
            let type = data.readType(Int(cursor) + 4)
            var boxSize = UInt64(size32)
            var headerLen: UInt64 = 8
            if size32 == 1 {
                boxSize = data.readU64(Int(cursor) + 8)
                headerLen = 16
            } else if size32 == 0 {
                boxSize = UInt64(data.count) - cursor
            }
            if boxSize < headerLen { throw DashHlsError.parse("bad box size at \(cursor)") }
            switch type {
            case "moov":
                let end = cursor + boxSize
                if end > UInt64(data.count) {
                    if track.isLocal {
                        throw DashHlsError.parse("moov exceeds preload")
                    }
                    // Overfetch so the sidx that follows moov is also covered.
                    let (more, _) = try await fetchRange(url: url, upTo: Int(end) + (512 << 10))
                    data = more
                }
                moovRange = Int(cursor) ..< Int(cursor + boxSize)
            case "sidx":
                sidxStart = cursor
                let end = cursor + boxSize
                if end > UInt64(data.count) {
                    if track.isLocal {
                        throw DashHlsError.parse("sidx exceeds preload")
                    }
                    let (more, _) = try await fetchRange(url: url, upTo: Int(end))
                    data = more
                }
                sidxData = data.subdata(in: Int(cursor) ..< Int(end))
            case "moof", "mdat":
                cursor = UInt64(data.count)  // stop walking
                continue
            default:
                break
            }
            if sidxData != nil { break }
            cursor += boxSize
        }

        guard let moovRange else { throw DashHlsError.parse("moov not found") }
        let moov = data.subdata(in: moovRange)
        let sample = Self.parseSampleEntry(moov: moov)
        track.codec = sample.codec
        track.videoRange = sample.videoRange

        guard let sidxData, let sidxStart else { throw DashHlsError.parse("sidx not found") }
        // The init segment is everything before the sidx box (ftyp+moov).
        track.initLength = sidxStart

        let sidx = try Self.parseSidx(sidxData, sidxEndOffset: sidxStart + UInt64(sidxData.count))
        track.segments = sidx.map { Segment(offset: $0.offset, size: $0.size, duration: $0.duration) }
        track.totalDuration = track.segments.reduce(0) { $0 + $1.duration }
        track.totalSize = track.segments.reduce(track.initLength) { $0 + $1.size }
        return track
    }

    private func fetchRange(url: String, upTo end: Int) async throws -> (Data, UInt64) {
        guard let requestUrl = URL(string: url) else { throw DashHlsError.parse("bad url") }
        var request = URLRequest(url: requestUrl)
        request.setValue("bytes=0-\(end - 1)", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // URLSession.data(for:) is iOS 15+, the app targets iOS 14.
        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: DashHlsError.parse("empty response"))
                }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw DashHlsError.parse("no response") }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw DashHlsError.http(http.statusCode)
        }
        var total = UInt64(data.count)
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let parsed = UInt64(totalPart) {
            total = parsed
        }
        return (data, total)
    }

    // MARK: - Playlist generation

    private func mediaUri(for track: Track, pathTag: String) -> String {
        if track.isLocal {
            return "\(Self.scheme)://bridge/file/\(pathTag)"
        }
        return track.url
    }

    private func mediaPlaylist(for track: Track, pathTag: String) -> Data {
        let target = max(1, Int(ceil(track.segments.map(\.duration).max() ?? 1)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        let uri = mediaUri(for: track, pathTag: pathTag)
        lines.append("#EXT-X-MAP:URI=\"\(uri)\",BYTERANGE=\"\(track.initLength)@0\"")
        for segment in track.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(uri)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n").data(using: .utf8)!
    }

    private func masterPlaylist(video: Track, audio: Track?) -> Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var streamInf: [String] = []
        let bandwidth = video.totalDuration > 0
            ? Int(Double(video.totalSize) * 8 / video.totalDuration)
            : 10_000_000
        streamInf.append("BANDWIDTH=\(max(bandwidth, 1))")
        var codecs: [String] = []
        if let codec = video.codec { codecs.append(codec) }
        if let audio, let codec = audio.codec { codecs.append(codec) }
        if !codecs.isEmpty {
            streamInf.append("CODECS=\"\(codecs.joined(separator: ","))\"")
        }
        if let range = video.videoRange {
            streamInf.append("VIDEO-RANGE=\(range)")
        }
        if audio != nil {
            lines.append(
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(Self.scheme)://bridge/audio.m3u8\""
            )
            streamInf.append("AUDIO=\"audio\"")
        }
        lines.append("#EXT-X-STREAM-INF:\(streamInf.joined(separator: ","))")
        lines.append("\(Self.scheme)://bridge/video.m3u8")
        return lines.joined(separator: "\n").data(using: .utf8)!
    }

    // MARK: - MP4 parsing helpers

    private struct SampleEntryInfo {
        var codec: String?
        var videoRange: String?
    }

    /// Finds the first sample entry of the first video/audio track inside the
    /// moov box and derives an RFC 6381 codec string plus HDR transfer info.
    private static func parseSampleEntry(moov: Data) -> SampleEntryInfo {
        var info = SampleEntryInfo()
        // moov > trak > mdia > minf > stbl > stsd
        forEachChild(of: moov, path: ["trak", "mdia", "minf", "stbl", "stsd"]) { stsd in
            guard stsd.count > 16 else { return }
            // stsd: version/flags (4) entry_count (4) then sample entries
            let entry = stsd.subdata(in: 8 ..< stsd.count)
            guard entry.count > 16 else { return }
            let fourcc = entry.readType(4)
            let body = entry.subdata(in: 8 ..< min(entry.count, Int(entry.readU32(0))))
            switch fourcc {
            case "avc1", "avc3":
                if let avcC = findBox(in: body, offset: 78, type: "avcC"), avcC.count >= 4 {
                    info.codec = String(format: "avc1.%02X%02X%02X", avcC[1], avcC[2], avcC[3])
                } else {
                    info.codec = "avc1.640028"
                }
            case "hvc1", "hev1":
                info.codec = hevcCodecString(prefix: fourcc, body: body) ?? "\(fourcc).1.6.L120.90"
                info.videoRange = videoRange(fromSampleEntryBody: body)
            case "dvh1", "dvhe":
                if let dv = dolbyVisionCodecString(prefix: fourcc, body: body) {
                    info.codec = dv
                } else {
                    info.codec = hevcCodecString(prefix: "hvc1", body: body)
                }
                info.videoRange = videoRange(fromSampleEntryBody: body) ?? "PQ"
            case "av01":
                info.codec = nil  // let AVPlayer probe; RFC string needs full av1C parse
                info.videoRange = videoRange(fromSampleEntryBody: body)
            case "mp4a":
                info.codec = aacCodecString(body: body)
            case "ec-3":
                info.codec = "ec-3"
            case "ac-3":
                info.codec = "ac-3"
            case "fLaC":
                info.codec = "fLaC"
            case "Opus":
                info.codec = "Opus"
            default:
                info.codec = nil
            }
        }
        return info
    }

    /// Video sample entries have a 78-byte fixed header, audio 28 bytes.
    private static func videoRange(fromSampleEntryBody body: Data) -> String? {
        guard let colr = findBox(in: body, offset: 78, type: "colr"), colr.count >= 7 else {
            return nil
        }
        let subtype = colr.readType(0)
        guard subtype == "nclx" || subtype == "nclc" else { return nil }
        let transfer = colr.readU16(6)
        switch transfer {
        case 16: return "PQ"
        case 18: return "HLG"
        default: return nil
        }
    }

    private static func hevcCodecString(prefix: String, body: Data) -> String? {
        guard let hvcC = findBox(in: body, offset: 78, type: "hvcC"), hvcC.count >= 13 else {
            return nil
        }
        let profileByte = hvcC[1]
        let profileSpace = profileByte >> 6
        let tierFlag = (profileByte >> 5) & 0x1
        let profileIdc = profileByte & 0x1F
        let compat = UInt32(hvcC.readU32(2))
        // RFC 6381 wants the compatibility flags bit-reversed.
        var reversed: UInt32 = 0
        for bit in 0 ..< 32 where (compat & (1 << UInt32(bit))) != 0 {
            reversed |= 1 << UInt32(31 - bit)
        }
        let level = hvcC[12]
        var parts = [String]()
        let spacePrefix = ["", "A", "B", "C"][Int(profileSpace)]
        parts.append("\(prefix).\(spacePrefix)\(profileIdc)")
        parts.append(String(format: "%X", reversed))
        parts.append("\(tierFlag == 0 ? "L" : "H")\(level)")
        // Constraint bytes, trailing zero bytes trimmed.
        var constraints: [UInt8] = (6 ..< 12).map { hvcC[$0] }
        while constraints.count > 1, constraints.last == 0 {
            constraints.removeLast()
        }
        parts.append(contentsOf: constraints.map { String(format: "%X", $0) })
        return parts.joined(separator: ".")
    }

    private static func dolbyVisionCodecString(prefix: String, body: Data) -> String? {
        guard let dvcC = findBox(in: body, offset: 78, type: "dvcC")
            ?? findBox(in: body, offset: 78, type: "dvvC"),
            dvcC.count >= 4
        else { return nil }
        let profile = dvcC[2] >> 1
        let level = ((dvcC[2] & 0x1) << 5) | (dvcC[3] >> 3)
        return String(format: "%@.%02d.%02d", prefix, profile, level)
    }

    private static func aacCodecString(body: Data) -> String {
        // Audio sample entry fixed part is 28 bytes, then child boxes (esds).
        guard let esds = findBox(in: body, offset: 28, type: "esds") else { return "mp4a.40.2" }
        // Scan the ES descriptor for the DecoderConfigDescriptor (tag 0x04),
        // whose first byte is the objectTypeIndication.
        var index = 4  // skip version/flags
        while index < esds.count {
            let tag = esds[index]
            index += 1
            var length = 0
            while index < esds.count {
                let byte = esds[index]
                index += 1
                length = (length << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            if tag == 0x03 {  // ES_Descriptor: skip ES_ID + flags, then recurse
                index += 3
                continue
            }
            if tag == 0x04 {  // DecoderConfigDescriptor
                guard index < esds.count else { break }
                let objectType = esds[index]
                if objectType == 0x40, index + 13 < esds.count {
                    // Find the DecoderSpecificInfo (tag 0x05) for the AOT.
                    var inner = index + 13
                    if inner + 1 < esds.count, esds[inner] == 0x05 {
                        inner += 1
                        while inner < esds.count, esds[inner] & 0x80 != 0 { inner += 1 }
                        inner += 1
                        if inner < esds.count {
                            let aot = esds[inner] >> 3
                            return "mp4a.40.\(aot)"
                        }
                    }
                    return "mp4a.40.2"
                }
                return String(format: "mp4a.%02X", objectType)
            }
            index += length
        }
        return "mp4a.40.2"
    }

    /// Iterates nested boxes along `path`, calling `visit` with each terminal
    /// box's payload. Only the first matching branch is visited.
    private static func forEachChild(of box: Data, path: [String], visit: (Data) -> Void) {
        guard let head = path.first else {
            visit(box)
            return
        }
        var cursor = 8  // skip the container's own header
        if path.count == 1, box.count > 8 {
            // parent payload offset handled by caller
        }
        while cursor + 8 <= box.count {
            let size = Int(box.readU32(cursor))
            let type = box.readType(cursor + 4)
            if size < 8 || cursor + size > box.count { return }
            if type == head {
                var payload = box.subdata(in: cursor ..< cursor + size)
                if path.count == 1 {
                    payload = payload.subdata(in: 8 ..< payload.count)
                    visit(payload)
                    return
                }
                forEachChild(of: payload, path: Array(path.dropFirst()), visit: visit)
                return
            }
            cursor += size
        }
    }

    /// Finds a child box inside a sample entry body starting at `offset`.
    /// Returns the payload (without the 8-byte header).
    private static func findBox(in body: Data, offset: Int, type: String) -> Data? {
        var cursor = offset
        while cursor + 8 <= body.count {
            let size = Int(body.readU32(cursor))
            let boxType = body.readType(cursor + 4)
            if size < 8 || cursor + size > body.count { return nil }
            if boxType == type {
                return body.subdata(in: cursor + 8 ..< cursor + size)
            }
            cursor += size
        }
        return nil
    }

    private static func parseSidx(
        _ sidx: Data,
        sidxEndOffset: UInt64
    ) throws -> [(offset: UInt64, size: UInt64, duration: Double)] {
        // sidx payload begins after the 8-byte box header.
        guard sidx.count >= 32 else { throw DashHlsError.parse("sidx too small") }
        let version = sidx[8]
        let timescale = UInt64(sidx.readU32(16))
        guard timescale > 0 else { throw DashHlsError.parse("sidx timescale 0") }
        var cursor: Int
        var firstOffset: UInt64
        if version == 0 {
            firstOffset = UInt64(sidx.readU32(24))
            cursor = 28
        } else {
            firstOffset = sidx.readU64(28)
            cursor = 36
        }
        cursor += 2  // reserved
        let count = Int(sidx.readU16(cursor))
        cursor += 2
        var anchor = sidxEndOffset + firstOffset
        var result: [(UInt64, UInt64, Double)] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            guard cursor + 12 <= sidx.count else { throw DashHlsError.parse("sidx truncated") }
            let sizeField = sidx.readU32(cursor)
            let referencedSize = UInt64(sizeField & 0x7FFF_FFFF)
            let duration = Double(sidx.readU32(cursor + 4)) / Double(timescale)
            result.append((anchor, referencedSize, duration))
            anchor += referencedSize
            cursor += 12
        }
        return result
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension DashHlsBridge: AVAssetResourceLoaderDelegate {
    var resourceLoaderQueue: DispatchQueue { loaderQueue }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else {
            return false
        }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path

        if let playlist = playlists[url.lastPathComponent], !path.hasPrefix("file/") {
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(playlist.count)
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = loadingRequest.dataRequest {
                let start = Int(dataRequest.requestedOffset)
                let end = min(playlist.count, start + dataRequest.requestedLength)
                if start < end {
                    dataRequest.respond(with: playlist.subdata(in: start ..< end))
                }
            }
            loadingRequest.finishLoading()
            return true
        }

        if path.hasPrefix("file/"), let fileUrl = localFiles[String(path.dropFirst(5))] {
            serveLocalFile(fileUrl, loadingRequest: loadingRequest)
            return true
        }

        loadingRequest.finishLoading(with: DashHlsError.parse("unknown resource \(path)"))
        return true
    }

    private func serveLocalFile(_ fileUrl: URL, loadingRequest: AVAssetResourceLoadingRequest) {
        loaderQueue.async {
            do {
                let handle = try FileHandle(forReadingFrom: fileUrl)
                defer { try? handle.close() }
                let total = handle.seekToEndOfFile()
                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = "public.mpeg-4"
                    info.contentLength = Int64(total)
                    info.isByteRangeAccessSupported = true
                }
                if let dataRequest = loadingRequest.dataRequest {
                    let start = UInt64(max(0, dataRequest.requestedOffset))
                    let length = UInt64(dataRequest.requestedLength)
                    let end = min(total, start + length)
                    if start < end {
                        handle.seek(toFileOffset: start)
                        // Stream in 4 MiB slices so huge segments do not spike memory.
                        var remaining = end - start
                        while remaining > 0 {
                            let chunk = handle.readData(ofLength: Int(min(remaining, 4 << 20)))
                            if chunk.isEmpty { break }
                            dataRequest.respond(with: chunk)
                            remaining -= UInt64(chunk.count)
                        }
                    }
                }
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
    }
}

// MARK: - Data readers

extension Data {
    func readU16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return (UInt16(self[startIndex + offset]) << 8) | UInt16(self[startIndex + offset + 1])
    }

    func readU32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value = (value << 8) | UInt32(self[startIndex + offset + i])
        }
        return value
    }

    func readU64(_ offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value = (value << 8) | UInt64(self[startIndex + offset + i])
        }
        return value
    }

    func readType(_ offset: Int) -> String {
        guard offset + 4 <= count else { return "" }
        let bytes = subdata(in: startIndex + offset ..< startIndex + offset + 4)
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    subscript(safe offset: Int) -> UInt8 {
        self[startIndex + offset]
    }
}
