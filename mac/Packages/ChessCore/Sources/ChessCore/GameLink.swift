import Foundation

/// A web link to a game, resolved to the URL that actually serves its moves.
public struct GameLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case lichessGame, lichessStudy
        case chessCom(daily: Bool)
        case chessgames
        case generic
    }

    public var kind: Kind
    /// Where to fetch the game from.
    public var fetchURL: URL
    /// Value for the Accept header, if the endpoint needs one.
    public var accept: String?
    /// The link asked for the board from Black's side (lichess `/black`).
    public var flipped: Bool
    /// Short name of the site, e.g. "lichess.org".
    public var source: String

    private static let lichessReserved: Set<String> = [
        "analysis", "training", "practice", "tutorial", "settings", "tv", "games", "streamer",
    ]

    /// Recognises lichess, chess.com, chessgames.com and other http(s) links. Returns nil for anything that is not a web link.
    public static func parse(_ url: URL) -> GameLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)

        if host == "lichess.org" || host.hasSuffix(".lichess.org") {
            // Study chapter: /study/<8>/<8>
            if parts.count >= 3, parts[0] == "study", isID(parts[1], [8]), isID(parts[2], [8]),
               let u = URL(string: "https://lichess.org/api/study/\(parts[1])/\(parts[2]).pgn") {
                return GameLink(kind: .lichessStudy, fetchURL: u, accept: "application/x-chess-pgn", flipped: false, source: "lichess.org")
            }
            // Game: /<8 or 12>[/white|/black]; the exporter wants the 8-character game id.
            if let first = parts.first, isID(first, [8, 12]), !lichessReserved.contains(first.lowercased()),
               parts.count == 1 || (parts.count == 2 && ["white", "black"].contains(parts[1])),
               let u = URL(string: "https://lichess.org/game/export/\(first.prefix(8))") {
                return GameLink(kind: .lichessGame, fetchURL: u, accept: "application/x-chess-pgn", flipped: parts.count == 2 && parts[1] == "black", source: "lichess.org")
            }
        }

        if host == "chess.com" || host.hasSuffix(".chess.com") {
            // /game/live/<id>, /game/daily/<id>, /analysis/game/live/<id>, the older /live/game/<id> and /daily/game/<id>,
            // and the bare /game/<id> (a live game).
            var p = Array(parts.drop { $0 == "analysis" })
            if p.count >= 3, ["live", "daily"].contains(p[0]), p[1] == "game" { p.swapAt(0, 1) }
            if p.count == 2, p[0] == "game" { p.insert("live", at: 1) }
            if p.count >= 3, p[0] == "game", ["live", "daily"].contains(p[1]) {
                let id = p[2]
                let daily = p[1] == "daily"
                if !id.isEmpty, id.allSatisfy(\.isNumber),
                   let u = URL(string: "https://www.chess.com/callback/\(daily ? "daily" : "live")/game/\(id)") {
                    return GameLink(kind: .chessCom(daily: daily), fetchURL: u, accept: "application/json", flipped: false, source: "chess.com")
                }
            }
        }

        if host == "chessgames.com" || host.hasSuffix(".chessgames.com") {
            // Any page carrying ?gid=<n>, e.g. /perl/chessgame?gid=1011478.
            let gid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name.lowercased() == "gid" }?.value
            if let gid, !gid.isEmpty, gid.allSatisfy(\.isNumber),
               let u = URL(string: "https://www.chessgames.com/nodejs/game/viewGamePGN?text=1&gid=\(gid)") {
                return GameLink(kind: .chessgames, fetchURL: u, accept: nil, flipped: false, source: "chessgames.com")
            }
        }

        let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return GameLink(kind: .generic, fetchURL: url, accept: nil, flipped: false, source: label)
    }

    /// The URL, if `text` is nothing but a single http(s) link.
    public static func url(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace),
              let u = URL(string: t), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              u.host?.isEmpty == false else { return nil }
        return u
    }

    private static func isID(_ s: String, _ lengths: [Int]) -> Bool {
        lengths.contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
