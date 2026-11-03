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

    static func audioURL(for videoID: String) async throws -> URL {
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
