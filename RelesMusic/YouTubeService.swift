import Foundation
import YouTubeKit

enum YouTubeError: LocalizedError {
    case noPlayableStream, invalidLink

    var errorDescription: String? {
        switch self {
        case .noPlayableStream: return "No se encontró audio reproducible."
        case .invalidLink: return "El enlace no es de YouTube."
        }
    }
}

enum YouTubeService {
    // MARK: Búsqueda (API interna de YouTube, sin clave)

    static func search(_ query: String) async throws -> [Track] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20251101.00.00", "hl": "es", "gl": "ES"]],
            "query": query,
            "params": "EgIQAQ==" // solo vídeos
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data)

        var renderers: [[String: Any]] = []
        collectVideoRenderers(json, into: &renderers)

        var seen = Set<String>()
        return renderers.compactMap { r -> Track? in
            guard let id = r["videoId"] as? String, seen.insert(id).inserted,
                  let title = text(r["title"]) else { return nil }
            let artist = text(r["ownerText"]) ?? text(r["longBylineText"]) ?? ""
            let duration = (r["lengthText"] as? [String: Any])?["simpleText"] as? String
            return Track(id: id, title: title, artist: artist, duration: duration)
        }
    }

    private static func collectVideoRenderers(_ node: Any, into result: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let vr = dict["videoRenderer"] as? [String: Any] { result.append(vr) }
            for value in dict.values { collectVideoRenderers(value, into: &result) }
        } else if let array = node as? [Any] {
            for value in array { collectVideoRenderers(value, into: &result) }
        }
    }

    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    // MARK: Audio

    /// Primero prueba la vía rápida (una sola petición); si falla, usa YouTubeKit (más lento pero más fiable).
    static func audioURL(for videoID: String, allowFastPath: Bool = true) async throws -> URL {
        if allowFastPath, let url = try? await fastAudioURL(for: videoID) { return url }
        let streams = try await YouTube(videoID: videoID, methods: [.local, .remote]).streams
        let audio = streams.filterAudioOnly().filter { $0.isNativelyPlayable }
        if let stream = audio.filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream()
            ?? audio.highestAudioBitrateStream() {
            return stream.url
        }
        // Último recurso: vídeo+audio (más datos, pero suena igual)
        if let stream = streams.filterVideoAndAudio().filter({ $0.isNativelyPlayable }).first {
            return stream.url
        }
        throw YouTubeError.noPlayableStream
    }

    // MARK: Vía rápida (API de la app oficial de YouTube para iPhone)

    private static let iosClientVersion = "20.10.4"

    private static func fastAudioURL(for videoID: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.ios.youtube/\(iosClientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(iosClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "IOS", "clientVersion": iosClientVersion,
                "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                "osName": "iPhone", "osVersion": "18.3.2.22D82",
                "hl": "es", "gl": "ES"
            ]],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK",
              let streaming = json["streamingData"] as? [String: Any] else {
            throw YouTubeError.noPlayableStream
        }

        // 1º: solo audio m4a (gasta menos datos), comprobando que YouTube deja descargarlo
        let formats = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        let audio = formats
            .filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true }
            .sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }
        if let string = audio.first?["url"] as? String, let url = URL(string: string), await isReachable(url) {
            return url
        }

        // 2º: lista HLS, que AVPlayer reproduce directamente
        if let string = streaming["hlsManifestUrl"] as? String, let url = URL(string: string) {
            return url
        }
        throw YouTubeError.noPlayableStream
    }

    private static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = 4
        let result = try? await URLSession.shared.data(for: request)
        guard let http = result?.1 as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    static func isHLS(_ url: URL) -> Bool {
        url.host?.contains("manifest.googlevideo.com") == true || url.pathExtension == "m3u8"
    }

    // MARK: Enlaces

    static func videoID(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return s }
        guard let comps = URLComponents(string: s), let host = comps.host else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = comps.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be"), let first = parts.first { return first }
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }), i + 1 < parts.count {
            return parts[i + 1]
        }
        return nil
    }

    private struct OEmbed: Decodable {
        let title: String
        let author_name: String
    }

    static func track(fromLink link: String) async throws -> Track {
        guard let id = videoID(from: link) else { throw YouTubeError.invalidLink }
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let info = try JSONDecoder().decode(OEmbed.self, from: data)
        return Track(id: id, title: info.title, artist: info.author_name)
    }
}
