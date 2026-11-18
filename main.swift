import Cocoa
import SwiftUI
import CryptoKit

// MARK: - 1. 原生繁简转换与元数据清洗
func toSimplified(_ s: String) -> String {
    let mutable = NSMutableString(string: s) as CFMutableString
    CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
    return mutable as String
}

func decodeHTMLEntities(_ s: String) -> String {
    var res = s
    let pairs: [(String, String)] = [
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&quot;", "\""),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&#32;", " "),
        ("&nbsp;", " ")
    ]
    for p in pairs {
        res = res.replacingOccurrences(of: p.0, with: p.1)
    }
    return res
}

func cleanTrackTitle(_ title: String) -> String {
    var t = title
    let patterns = [
        "\\s*-\\s*(Remastered|20\\d\\d Remaster|Live|Single Version|Radio Edit|Bonus Track).*",
        "\\s*\\((feat\\.|ft\\.|Remastered|Live|现场版|单曲版|Official|Music Video|Audio).*?\\)",
        "\\s*\\[(feat\\.|ft\\.|Remastered|Live|现场版|单曲版|Official|Music Video|Audio).*?\\]"
    ]
    for p in patterns {
        if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
            t = regex.stringByReplacingMatches(in: t, options: [], range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        }
    }
    let res = t.trimmingCharacters(in: .whitespacesAndNewlines)
    return res.isEmpty ? title : res
}

func cleanArtistName(_ artist: String) -> String {
    let seps = [",", "/", "&", "、", "feat.", "ft."]
    var a = artist
    for s in seps {
        if let range = a.range(of: s, options: [.caseInsensitive]) {
            a = String(a[..<range.lowerBound])
        }
    }
    let res = a.trimmingCharacters(in: .whitespacesAndNewlines)
    return res.isEmpty ? artist : res
}

// MARK: - 2. 对唱角色识别与对齐判定引擎 (Apple Music 左右分栏)
enum DuetAlignment: Equatable {
    case leading   // 男方 / 主声 A (靠左)
    case trailing  // 女方 / 和声 B (靠右)
    case center    // 合唱 / 普通常规 (居中)
}

func parseDuetAlignment(text: String, artist: String) -> (DuetAlignment, String) {
    let t = text.trimmingCharacters(in: .whitespaces)

    let leftPrefixes = [
        "(男)", "[男]", "男:", "男：", "【男】", "(男声)", "[男声]", "男声:", "男声：",
        "(男唱)", "[男唱]", "男1:", "男2:"
    ]
    let rightPrefixes = [
        "(女)", "[女]", "女:", "女：", "【女】", "(女声)", "[女声]", "女声:", "女声：",
        "(女唱)", "[女唱]", "女1:", "女2:"
    ]
    let centerPrefixes = [
        "(合)", "[合]", "合:", "合：", "【合】", "(合唱)", "[合唱]", "合唱:", "合唱：",
        "(全体)", "[全体]", "全体:"
    ]

    for p in centerPrefixes {
        if t.hasPrefix(p) {
            let clean = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            return (.center, clean)
        }
    }

    for p in leftPrefixes {
        if t.hasPrefix(p) {
            let clean = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            return (.leading, clean)
        }
    }

    for p in rightPrefixes {
        if t.hasPrefix(p) {
            let clean = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            return (.trailing, clean)
        }
    }

    let subArtists = artist.components(separatedBy: CharacterSet(charactersIn: ",/&、"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    if subArtists.count >= 2 {
        let firstA = subArtists[0]
        let secondA = subArtists[1]
        if t.hasPrefix("\(firstA):") || t.hasPrefix("\(firstA)：") {
            let clean = String(t.dropFirst(firstA.count + 1)).trimmingCharacters(in: .whitespaces)
            return (.leading, clean)
        }
        if t.hasPrefix("\(secondA):") || t.hasPrefix("\(secondA)：") {
            let clean = String(t.dropFirst(secondA.count + 1)).trimmingCharacters(in: .whitespaces)
            return (.trailing, clean)
        }
    }

    return (.center, t)
}

// MARK: - 3. 字体色彩与字号档位管理器
enum LyricTheme: String, CaseIterable, Identifiable {
    case appleMusic = "classic"
    case aurora     = "aurora"
    case amber      = "amber"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: return "经典 Apple Music (流光纯白)"
        case .aurora:     return "极光霓虹 (Aurora Cyber)"
        case .amber:      return "暖玉琥珀 (Warm Amber)"
        }
    }

    var focusColor: Color {
        switch self {
        case .appleMusic: return Color.white
        case .aurora:     return Color(red: 0.35, green: 0.95, blue: 0.90)
        case .amber:      return Color(red: 1.00, green: 0.82, blue: 0.48)
        }
    }

    var dimColor: Color {
        switch self {
        case .appleMusic: return Color.white
        case .aurora:     return Color(red: 0.75, green: 0.88, blue: 0.95)
        case .amber:      return Color(red: 0.95, green: 0.88, blue: 0.75)
        }
    }
}

enum LyricFontSizeOption: Double, CaseIterable, Identifiable {
    case small    = 18.0
    case medium   = 24.0
    case standard = 30.0
    case large    = 40.0
    case xlarge   = 52.0
    case huge     = 68.0

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .small:    return "18 pt (精巧小字 · 容纳更多行)"
        case .medium:   return "24 pt (适中小字 · 经典视野)"
        case .standard: return "30 pt (标准推荐 · 均衡呼吸)"
        case .large:    return "40 pt (大字醒目 · 舒适观赏)"
        case .xlarge:   return "52 pt (超大画卷 · 气势磅礴)"
        case .huge:     return "68 pt (极限海报 · 巨幕大字)"
        }
    }
}

// MARK: - 4. 歌词数据模型与持久化双级缓存
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
    let alignment: DuetAlignment
}

class RobustLyricsCache {
    static let shared = RobustLyricsCache()
    private let cacheDir: URL
    private let memCache = NSCache<NSString, NSString>()

    init() {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDir = urls[0].appendingPathComponent("com.mobai.SpotifyLyrics").appendingPathComponent("Lyrics")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memCache.countLimit = 150
    }

    private func shaKey(artist: String, title: String) -> String {
        let raw = "\(cleanArtistName(artist).lowercased())___\(cleanTrackTitle(title).lowercased())"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func get(artist: String, title: String) -> String? {
        let key = shaKey(artist: artist, title: title)
        let nsKey = key as NSString

        if let mem = memCache.object(forKey: nsKey) {
            let str = mem as String
            return (str == "[EMPTY]" || isInvalidLyricContent(str)) ? nil : str
        }

        let file = cacheDir.appendingPathComponent("\(key).lrc")
        if let diskStr = try? String(contentsOf: file, encoding: .utf8) {
            if isInvalidLyricContent(diskStr) {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            memCache.setObject(diskStr as NSString, forKey: nsKey)
            return diskStr == "[EMPTY]" ? nil : diskStr
        }

        return nil
    }

    func isNegativeCached(artist: String, title: String) -> Bool {
        let key = shaKey(artist: artist, title: title)
        let nsKey = key as NSString
        if let mem = memCache.object(forKey: nsKey) {
            return (mem as String) == "[EMPTY]"
        }
        let file = cacheDir.appendingPathComponent("\(key).lrc")
        if let diskStr = try? String(contentsOf: file, encoding: .utf8) {
            return diskStr == "[EMPTY]"
        }
        return false
    }

    func set(artist: String, title: String, lyric: String) {
        if isInvalidLyricContent(lyric) {
            return
        }
        let key = shaKey(artist: artist, title: title)
        let nsKey = key as NSString
        memCache.setObject(lyric as NSString, forKey: nsKey)

        let file = cacheDir.appendingPathComponent("\(key).lrc")
        try? lyric.write(to: file, atomically: true, encoding: .utf8)
    }

    func setEmpty(artist: String, title: String) {
        let key = shaKey(artist: artist, title: title)
        let nsKey = key as NSString
        memCache.setObject("[EMPTY]" as NSString, forKey: nsKey)

        let file = cacheDir.appendingPathComponent("\(key).lrc")
        try? "[EMPTY]".write(to: file, atomically: true, encoding: .utf8)
    }

    func clearAll() {
        memCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func getCachedCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        return files.filter { $0.hasSuffix(".lrc") }.count
    }

    // 校验歌词质量：过滤伴奏/纯音乐/假歌词
    func isInvalidLyricContent(_ lrc: String) -> Bool {
        if lrc.contains("纯音乐，请欣赏") || lrc.contains("纯音乐") || lrc.contains("没有填词") {
            let lines = lrc.components(separatedBy: .newlines).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.contains("]") && !t.contains("作词") && !t.contains("作曲") && !t.contains("编曲")
            }
            if lines.count <= 3 {
                return true
            }
        }
        return false
    }
}

// MARK: - 5. 增强型三源级联检索引擎 (防串曲、防伴奏、防翻唱多维评分系统)
class LyricsEngine {
    static let shared = LyricsEngine()

    func fetchLyrics(title: String, artist: String, durationMs: Double, forceRefresh: Bool = false, completion: @escaping ([LyricLine]?) -> Void) {
        let spotifySec = durationMs / 1000.0

        if !forceRefresh {
            if let cached = RobustLyricsCache.shared.get(artist: artist, title: title) {
                let lines = parseLRC(cached, artist: artist)
                if !lines.isEmpty {
                    completion(lines)
                    return
                }
            } else if RobustLyricsCache.shared.isNegativeCached(artist: artist, title: title) {
                completion(nil)
                return
            }
        }

        let cleanT = cleanTrackTitle(title)
        let cleanA = cleanArtistName(artist)
        let simpT = toSimplified(cleanT)
        let simpA = toSimplified(cleanA)

        // 第一源：网易云多维打分
        fetchFromNetease(rawTitle: cleanT, rawArtist: cleanA, simpTitle: simpT, simpArtist: simpA, spotifySec: spotifySec) { [weak self] lrc1 in
            guard let self = self else { return }
            if let lrc = lrc1, !RobustLyricsCache.shared.isInvalidLyricContent(lrc) {
                let lines = self.parseLRC(lrc, artist: artist)
                if !lines.isEmpty {
                    RobustLyricsCache.shared.set(artist: artist, title: title, lyric: lrc)
                    completion(lines)
                    return
                }
            }

            // 第二源：QQ音乐多维打分
            self.fetchFromQQMusic(rawTitle: cleanT, rawArtist: cleanA, simpTitle: simpT, simpArtist: simpA, spotifySec: spotifySec) { [weak self] lrc2 in
                guard let self = self else { return }
                if let lrc = lrc2, !RobustLyricsCache.shared.isInvalidLyricContent(lrc) {
                    let lines = self.parseLRC(lrc, artist: artist)
                    if !lines.isEmpty {
                        RobustLyricsCache.shared.set(artist: artist, title: title, lyric: lrc)
                        completion(lines)
                        return
                    }
                }

                // 第三源：LRCLIB 精准匹配
                self.fetchFromLRCLIB(title: simpT, artist: simpA, spotifySec: spotifySec) { [weak self] lrc3 in
                    guard let self = self else { return }
                    if let lrc = lrc3, !RobustLyricsCache.shared.isInvalidLyricContent(lrc) {
                        let lines = self.parseLRC(lrc, artist: artist)
                        if !lines.isEmpty {
                            RobustLyricsCache.shared.set(artist: artist, title: title, lyric: lrc)
                            completion(lines)
                            return
                        }
                    }
                    RobustLyricsCache.shared.setEmpty(artist: artist, title: title)
                    completion(nil)
                }
            }
        }
    }

    private func computeConfidenceScore(candTitle: String, candArtist: String, targetTitle: String, targetArtist: String, candDuration: Double, targetDuration: Double) -> Double {
        var score: Double = 100.0

        let ct = toSimplified(candTitle).lowercased()
        let ca = toSimplified(candArtist).lowercased()
        let tt = toSimplified(targetTitle).lowercased()
        let ta = toSimplified(targetArtist).lowercased()

        // 1. 严格排斥干扰标签
        let negativeKeywords = ["伴奏", "纯音乐", "instrumental", "karaoke", "piano", "cover", "翻唱", "铃声"]
        for kw in negativeKeywords {
            if ct.contains(kw) && !tt.contains(kw) {
                return -999.0
            }
        }

        // 2. 歌手匹配权重
        if ca.contains(ta) || ta.contains(ca) {
            score += 40.0
        } else {
            score -= 50.0
        }

        // 3. 歌名匹配
        if ct == tt {
            score += 30.0
        } else if ct.contains(tt) || tt.contains(ct) {
            score += 15.0
        } else {
            score -= 40.0
        }

        // 4. 时长差异衰减
        let diff = abs(candDuration - targetDuration)
        if diff > 15.0 {
            return -999.0
        }
        score -= diff * 3.5

        return score
    }

    private func fetchFromNetease(rawTitle: String, rawArtist: String, simpTitle: String, simpArtist: String, spotifySec: Double, completion: @escaping (String?) -> Void) {
        let query = "\(simpTitle) \(simpArtist)"
        guard let encodedQ = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchUrl = URL(string: "https://music.163.com/api/search/get/web?s=\(encodedQ)&type=1&limit=8") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: searchUrl)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 3.5

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]], !songs.isEmpty else {
                completion(nil)
                return
            }

            var bestId: Int?
            var maxScore = -999.0

            for song in songs {
                guard let sid = song["id"] as? Int,
                      let durMs = song["duration"] as? Double,
                      let stitle = song["name"] as? String else { continue }

                var sartist = ""
                if let artists = song["artists"] as? [[String: Any]], let first = artists.first, let aName = first["name"] as? String {
                    sartist = aName
                }

                let score = self.computeConfidenceScore(
                    candTitle: stitle,
                    candArtist: sartist,
                    targetTitle: simpTitle,
                    targetArtist: simpArtist,
                    candDuration: durMs / 1000.0,
                    targetDuration: spotifySec
                )

                if score > maxScore {
                    maxScore = score
                    bestId = sid
                }
            }

            if let chosenId = bestId, maxScore >= 60.0 {
                let lrcUrl = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(chosenId)&lv=-1&kv=-1&tv=-1")!
                URLSession.shared.dataTask(with: lrcUrl) { lrcData, _, _ in
                    if let lrcData = lrcData,
                       let lrcJson = try? JSONSerialization.jsonObject(with: lrcData) as? [String: Any],
                       let lrcObj = lrcJson["lrc"] as? [String: Any],
                       let lrcText = lrcObj["lyric"] as? String, !lrcText.isEmpty {
                        completion(lrcText)
                        return
                    }
                    completion(nil)
                }.resume()
            } else {
                completion(nil)
            }
        }.resume()
    }

    private func fetchFromQQMusic(rawTitle: String, rawArtist: String, simpTitle: String, simpArtist: String, spotifySec: Double, completion: @escaping (String?) -> Void) {
        let query = "\(simpTitle) \(simpArtist)"
        guard let encodedQ = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchUrl = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(encodedQ)&format=json&n=8") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: searchUrl)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 3.5

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let songObj = dataObj["song"] as? [String: Any],
                  let songs = songObj["list"] as? [[String: Any]], !songs.isEmpty else {
                completion(nil)
                return
            }

            var bestMid: String?
            var maxScore = -999.0

            for song in songs {
                guard let mid = song["songmid"] as? String,
                      let interval = song["interval"] as? Double,
                      let stitle = song["songname"] as? String else { continue }

                var sartist = ""
                if let singers = song["singer"] as? [[String: Any]], let first = singers.first, let aName = first["name"] as? String {
                    sartist = aName
                }

                let score = self.computeConfidenceScore(
                    candTitle: stitle,
                    candArtist: sartist,
                    targetTitle: simpTitle,
                    targetArtist: simpArtist,
                    candDuration: interval,
                    targetDuration: spotifySec
                )

                if score > maxScore {
                    maxScore = score
                    bestMid = mid
                }
            }

            if let chosenMid = bestMid, maxScore >= 60.0 {
                let lrcUrl = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(chosenMid)&format=json&nobase64=1")!
                var lrcReq = URLRequest(url: lrcUrl)
                lrcReq.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
                URLSession.shared.dataTask(with: lrcReq) { lrcData, _, _ in
                    if let lrcData = lrcData,
                       let lrcJson = try? JSONSerialization.jsonObject(with: lrcData) as? [String: Any],
                       let lrcText = lrcJson["lyric"] as? String, !lrcText.isEmpty {
                        completion(lrcText)
                        return
                    }
                    completion(nil)
                }.resume()
            } else {
                completion(nil)
            }
        }.resume()
    }

    private func fetchFromLRCLIB(title: String, artist: String, spotifySec: Double, completion: @escaping (String?) -> Void) {
        let q = "track_name=\(title)&artist_name=\(artist)"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?\(encoded)") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.setValue("SpotifyFloatingLyrics/5.7", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 3.5

        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data,
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var bestLrc: String?
                var minDiff = 999.0
                for item in list {
                    if let synced = item["syncedLyrics"] as? String,
                       let dur = item["duration"] as? Double {
                        let diff = abs(dur - spotifySec)
                        if diff < minDiff {
                            minDiff = diff
                            bestLrc = synced
                        }
                    }
                }
                if let raw = bestLrc, minDiff <= 12.0 {
                    completion(raw)
                    return
                }
            }
            completion(nil)
        }.resume()
    }

    private func parseLRC(_ lrc: String, artist: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let lines = lrc.components(separatedBy: .newlines)

        var globalOffsetSeconds: Double = 0.0
        let offsetRegex = try? NSRegularExpression(pattern: "\\[offset:\\s*([+-]?\\d+)\\]", options: [.caseInsensitive])
        for line in lines.prefix(15) {
            let ns = line as NSString
            if let match = offsetRegex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let valStr = ns.substring(with: match.range(at: 1))
                if let ms = Double(valStr) {
                    globalOffsetSeconds = ms / 1000.0
                }
            }
        }

        let pattern = "\\[(\\d+):(\\d+\\.?\\d*)\\](.*)"
        let regex = try? NSRegularExpression(pattern: pattern)
        var lineIndex = 0

        for line in lines {
            let nsLine = line as NSString
            if let match = regex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let mStr = nsLine.substring(with: match.range(at: 1))
                let sStr = nsLine.substring(with: match.range(at: 2))
                var rawText = nsLine.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)

                rawText = decodeHTMLEntities(rawText)

                if rawText.contains("作词") || rawText.contains("作曲") || rawText.contains("编曲") ||
                   rawText.contains("制作") || rawText.contains("监制") || rawText.hasPrefix("by:") ||
                   rawText.hasPrefix("ti:") || rawText.hasPrefix("ar:") || rawText.hasPrefix("al:") {
                    continue
                }

                let (align, cleanText) = parseDuetAlignment(text: rawText, artist: artist)

                if let m = Double(mStr), let s = Double(sStr) {
                    let adjustedTime = max(0.0, m * 60.0 + s + globalOffsetSeconds)
                    result.append(LyricLine(id: lineIndex, time: adjustedTime, text: cleanText, alignment: align))
                    lineIndex += 1
                }
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

// MARK: - 6. Spotify 通信
class SpotifyController {
    static let shared = SpotifyController()

    func runScript(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    func getState() -> (isPlaying: Bool, title: String, artist: String, pos: Double, durMs: Double)? {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then
                    return (name of current track) & "|||" & (artist of current track) & "|||" & (player position as string) & "|||" & (duration of current track as string)
                else
                    return "PAUSED"
                end if
            end tell
        else
            return "NOT_RUNNING"
        end if
        """
        let out = runScript(script)
        if out == "PAUSED" || out == "NOT_RUNNING" || out.isEmpty {
            return nil
        }
        let parts = out.components(separatedBy: "|||")
        if parts.count >= 4,
           let pos = Double(parts[2]),
           let dur = Double(parts[3]) {
            return (true, parts[0].trimmingCharacters(in: .whitespacesAndNewlines), parts[1].trimmingCharacters(in: .whitespacesAndNewlines), pos, dur)
        }
        return nil
    }

    func seek(to seconds: Double) {
        guard seconds >= 0 else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            _ = self.runScript("""
            if application "Spotify" is running then
                tell application "Spotify" to set player position to \(seconds)
            end if
            """)
        }
    }

    func previous() {
        DispatchQueue.global(qos: .userInteractive).async {
            _ = self.runScript("if application \"Spotify\" is running then tell application \"Spotify\" to previous track")
        }
    }

    func next() {
        DispatchQueue.global(qos: .userInteractive).async {
            _ = self.runScript("if application \"Spotify\" is running then tell application \"Spotify\" to next track")
        }
    }

    func playPause() {
        DispatchQueue.global(qos: .userInteractive).async {
            _ = self.runScript("if application \"Spotify\" is running then tell application \"Spotify\" to playpause")
        }
    }
}

// MARK: - 7. 原生桌面毛玻璃透视组件 (NSVisualEffectView behindWindow)
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        view.layer?.cornerRadius = 20
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - 8. 视图状态中心 (以用户选择字号为核心，联动高度自适应展开行数)
class LyricViewModel: ObservableObject {
    @Published var lyrics: [LyricLine] = []
    @Published var currentIndex: Int = -1
    @Published var placeholderTitle: String = "🎵 正在连接 Spotify..."
    @Published var placeholderSubtitle: String = "请在 Spotify 播放歌曲"
    @Published var isShowingLyrics: Bool = false
    @Published var mainFontSize: CGFloat = 30.0
    @Published var displayLineCount: Int = 3
    @Published var isHovered: Bool = false
    @Published var isPlayingState: Bool = false
    @Published var theme: LyricTheme = .appleMusic
    @Published var isGlassDisabled: Bool = false
    @Published var userSelectedFontSize: CGFloat = 30.0

    private var lastTrackKey: String = ""
    private var currentTitle: String = ""
    private var currentArtist: String = ""
    private var requestToken: UUID = UUID()

    private var basePosition: Double = 0
    private var baseMediaTime: Double = 0
    private var smoothedOffsetCorrection: Double = 0.0
    private var lastPollTime: Double = 0
    private var isPollingInProgress: Bool = false
    private var consecutivePauseCount: Int = 0

    private var currentWindowWidth: CGFloat = 560
    private var currentWindowHeight: CGFloat = 110

    init() {
        let savedTheme = UserDefaults.standard.string(forKey: "LyricTheme") ?? LyricTheme.appleMusic.rawValue
        self.theme = LyricTheme(rawValue: savedTheme) ?? .appleMusic
        self.isGlassDisabled = UserDefaults.standard.bool(forKey: "isGlassDisabled")
        let savedFont = UserDefaults.standard.double(forKey: "UserSelectedFontSize")
        self.userSelectedFontSize = savedFont >= 16.0 ? CGFloat(savedFont) : 30.0
        self.mainFontSize = self.userSelectedFontSize

        setupDistributedNotification()
    }

    func setTheme(_ t: LyricTheme) {
        self.theme = t
        UserDefaults.standard.set(t.rawValue, forKey: "LyricTheme")
    }

    func setUserFontSize(_ size: CGFloat) {
        self.userSelectedFontSize = size
        UserDefaults.standard.set(Double(size), forKey: "UserSelectedFontSize")
        recomputeFontAndLines()
    }

    func toggleGlassMode() {
        self.isGlassDisabled.toggle()
        UserDefaults.standard.set(self.isGlassDisabled, forKey: "isGlassDisabled")
    }

    private func setupDistributedNotification() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.consecutivePauseCount = 0
            self?.pollSpotify(forceSync: true)
        }
    }

    func onTick() {
        let now = CACurrentMediaTime()
        let interval: Double = isPlayingState ? 4.5 : 2.5
        if now - lastPollTime >= interval {
            lastPollTime = now
            pollSpotify(forceSync: false)
        } else if isPlayingState {
            smoothedOffsetCorrection *= 0.90
            let interpolatedPos = basePosition + (now - baseMediaTime) + smoothedOffsetCorrection
            updateLyricsPosition(pos: interpolatedPos)
        }
    }

    func seekToLine(time: Double) {
        guard time >= 0 else { return }
        SpotifyController.shared.seek(to: time)
        basePosition = time
        baseMediaTime = CACurrentMediaTime()
        smoothedOffsetCorrection = 0.0
        updateLyricsPosition(pos: time)
    }

    func reloadCurrent() {
        guard !currentTitle.isEmpty else { return }
        lastTrackKey = ""
        isShowingLyrics = false
        placeholderTitle = "🔄 重新检索中..."
        placeholderSubtitle = "\(currentTitle) - \(currentArtist)"
        pollSpotify(forceSync: true, forceRefreshNetwork: true)
    }

    func updateDimensions(width: CGFloat, height: CGFloat) {
        self.currentWindowWidth = width
        self.currentWindowHeight = height
        recomputeFontAndLines()
    }

    // 【核心算法重构】：字号真正随用户设置生效 + 高度拉大后自适应铺满更多行数
    private func recomputeFontAndLines() {
        let height = currentWindowHeight
        let baseSize = userSelectedFontSize

        if height < 75 {
            // 单行迷你胶囊模式
            self.displayLineCount = 1
            self.mainFontSize = min(baseSize * 1.15, height * 0.65)
            return
        }

        // 以该字号对应的黄金行高槽位 (slotHeight) 自适应推导当前高度能舒适容纳几行
        let slotHeight = baseSize * 1.48
        let rawCount = Int(height / slotHeight)
        // 保证奇数行居中呈现 (3, 5, 7, 9, 11, 13, 15, 17, 19, 21)
        let oddCount = (rawCount % 2 == 1) ? rawCount : (rawCount - 1)
        let targetLines = max(3, min(oddCount, 21))

        // 真实行高
        let actualRowHeight = height / CGFloat(targetLines)
        // 字号严格以用户选择的 baseSize 为主导，并在极小高度时安全微调
        let finalSize = min(baseSize, actualRowHeight * 0.72)

        if self.displayLineCount != targetLines || abs(self.mainFontSize - finalSize) > 0.3 {
            self.displayLineCount = targetLines
            self.mainFontSize = max(14.0, finalSize)
        }
    }

    private func pollSpotify(forceSync: Bool, forceRefreshNetwork: Bool = false) {
        guard !isPollingInProgress else { return }
        isPollingInProgress = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let state = SpotifyController.shared.getState()

            DispatchQueue.main.async {
                self.isPollingInProgress = false
                guard let state = state else {
                    self.consecutivePauseCount += 1
                    if self.consecutivePauseCount >= 2 || forceSync {
                        self.isPlayingState = false
                        self.isShowingLyrics = false
                        if !self.currentTitle.isEmpty {
                            self.placeholderTitle = "⏸ Spotify 已暂停"
                            self.placeholderSubtitle = "\(self.currentTitle) - \(self.currentArtist)"
                        } else {
                            self.placeholderTitle = "等待 Spotify 播放..."
                            self.placeholderSubtitle = ""
                        }
                    }
                    return
                }

                self.consecutivePauseCount = 0
                self.isPlayingState = true
                let now = CACurrentMediaTime()

                let currentEstimated = self.basePosition + (now - self.baseMediaTime)
                let drift = state.pos - currentEstimated

                if abs(drift) > 2.0 || forceSync {
                    self.basePosition = state.pos
                    self.baseMediaTime = now
                    self.smoothedOffsetCorrection = 0.0
                } else if abs(drift) >= 0.05 {
                    self.smoothedOffsetCorrection += drift * 0.4
                    self.basePosition = state.pos
                    self.baseMediaTime = now
                }

                let trackKey = "\(state.artist) - \(state.title)"
                if trackKey != self.lastTrackKey || forceSync {
                    self.lastTrackKey = trackKey
                    self.currentTitle = state.title
                    self.currentArtist = state.artist
                    self.lyrics = []
                    self.currentIndex = -1
                    self.isShowingLyrics = false

                    self.placeholderTitle = "🎵 \(state.title)"
                    self.placeholderSubtitle = "\(state.artist) · 秒速载入中..."

                    let currentToken = UUID()
                    self.requestToken = currentToken

                    LyricsEngine.shared.fetchLyrics(title: state.title, artist: state.artist, durationMs: state.durMs, forceRefresh: forceRefreshNetwork) { [weak self] list in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            guard self.requestToken == currentToken else { return }

                            if let list = list, !list.isEmpty {
                                self.lyrics = list
                                self.isShowingLyrics = true
                                self.updateLyricsPosition(pos: self.basePosition)
                            } else {
                                self.placeholderTitle = "🎵 \(state.title)"
                                self.placeholderSubtitle = "\(state.artist) (三源检索完毕，暂无匹配歌词)"
                            }
                        }
                    }
                } else {
                    self.updateLyricsPosition(pos: state.pos)
                }
            }
        }
    }

    private func updateLyricsPosition(pos: Double) {
        guard !lyrics.isEmpty else { return }

        var newIndex = -1
        for (idx, line) in lyrics.enumerated() {
            if pos >= line.time {
                newIndex = idx
            } else {
                break
            }
        }

        if newIndex != self.currentIndex {
            // 关键：采用临界阻尼弹簧 (dampingFraction: 1.0)，物理上彻底消除到达目标后的回弹微振荡（Zero Ringing/Zero Jitter）
            withAnimation(.spring(response: 0.38, dampingFraction: 1.0, blendDuration: 0.10)) {
                self.currentIndex = newIndex
            }
        }
    }
}

// MARK: - 9. 悬浮主视图 (GPU 零过载架构：纯硬件透明度阶梯 + 单层微暗影)
struct LyricFloatingView: View {
    @ObservedObject var vm: LyricViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. 背景层
                if !vm.isGlassDisabled {
                    VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.20))
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(white: 0.08).opacity(0.85))
                }

                // 2. 拟态 1px 细微光反光描边
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // 3. 歌词渲染区
                if vm.isShowingLyrics && !vm.lyrics.isEmpty {
                    if vm.displayLineCount == 1 {
                        singleLineCapsuleView
                    } else {
                        multiLineZeroGpuOverheadView(geo: geo)
                    }
                } else {
                    placeholderView
                }

                // 4. 悬停迷你切歌条
                if vm.isHovered {
                    hoverControlsBar
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.18)) {
                    vm.isHovered = hovering
                }
            }
        }
    }

    // MARK: 单行迷你胶囊视图 (平滑呼吸位移)
    private var singleLineCapsuleView: some View {
        let curLine = (vm.currentIndex >= 0 && vm.currentIndex < vm.lyrics.count)
            ? vm.lyrics[vm.currentIndex]
            : nil

        return VStack {
            if let line = curLine {
                Text(line.text.isEmpty ? "···" : line.text)
                    .id(line.id)
                    .font(.system(size: vm.mainFontSize, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundColor(vm.theme.focusColor)
                    .shadow(color: Color.black.opacity(0.70), radius: 1.5, x: 0, y: 1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .padding(.horizontal, 22)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity.combined(with: .offset(y: -8))
                    ))
            } else {
                Text("🎵 前奏中...")
                    .font(.system(size: vm.mainFontSize, weight: .medium, design: .rounded))
                    .foregroundColor(vm.theme.dimColor.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 多行连续位移推移 (零抖动、零重排、临界阻尼硬件平移)
    private func multiLineZeroGpuOverheadView(geo: GeometryProxy) -> some View {
        let rowHeight = geo.size.height / CGFloat(max(1, vm.displayLineCount))
        let targetIdx = max(0, vm.currentIndex)
        let centerOffset = (geo.size.height - rowHeight) / 2.0
        let currentY = -CGFloat(targetIdx) * rowHeight + centerOffset

        // 宽裕对称视口：预留足够前后缓冲区，防止视口切片突入抖动
        let half = max(vm.displayLineCount / 2, 2) + 3
        let minIdx = max(0, targetIdx - half)
        let maxIdx = min(vm.lyrics.count - 1, targetIdx + half)
        let visibleSlice = (minIdx <= maxIdx) ? Array(vm.lyrics[minIdx...maxIdx]) : []

        return ZStack(alignment: .top) {
            ForEach(visibleSlice) { line in
                let dist = abs(line.id - vm.currentIndex)
                let isCur = (line.id == vm.currentIndex)

                // 纯硬件级透明度与缩放阶梯
                let opacity: Double = isCur ? 1.0 : (dist == 1 ? 0.48 : (dist == 2 ? 0.22 : (dist == 3 ? 0.12 : 0.05)))
                let scale: CGFloat = isCur ? 1.04 : (dist == 1 ? 0.92 : (dist == 2 ? 0.84 : 0.78))
                let lineY = CGFloat(line.id) * rowHeight + currentY

                HStack {
                    if line.alignment == .trailing {
                        Spacer()
                    }

                    Text(line.text.isEmpty ? "···" : line.text)
                        // 关键：字号与字重（.semibold）全局恒定统一！绝对不在当前行/非当前行切换字重，彻底消除从粗体切换到细体时字符宽度突变引发的抽搐跳动！
                        .font(.system(
                            size: vm.mainFontSize,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .tracking(0.3)
                        .foregroundColor(isCur ? vm.theme.focusColor : vm.theme.dimColor.opacity(opacity))
                        .shadow(color: Color.black.opacity(isCur ? 0.65 : 0.25), radius: 1.5, x: 0, y: 1.0)
                        // 关键：纯 GPU 硬件纹理缩放，零 CPU 参与，彻底消除文字字距物理抖动！
                        .scaleEffect(
                            scale,
                            anchor: line.alignment == .leading ? .leading : (line.alignment == .trailing ? .trailing : .center)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                        .padding(.horizontal, 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.seekToLine(time: line.time)
                        }

                    if line.alignment == .leading {
                        Spacer()
                    }
                }
                .frame(width: geo.size.width, height: rowHeight)
                // 关键：纯 GPU 硬件矩阵位移，完全取代触发频繁重排的 .position()
                .offset(x: 0, y: lineY)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        .clipped()
    }

    // MARK: 占位提示视图
    private var placeholderView: some View {
        VStack(spacing: 5) {
            Text(vm.placeholderTitle)
                .font(.system(size: vm.mainFontSize, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundColor(vm.theme.focusColor)
                .shadow(color: Color.black.opacity(0.70), radius: 2, x: 0, y: 1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .padding(.horizontal, 20)

            HStack(spacing: 6) {
                Text(vm.placeholderSubtitle)
                    .font(.system(size: max(12, vm.mainFontSize * 0.60), weight: .medium, design: .rounded))
                    .foregroundColor(vm.theme.dimColor.opacity(0.65))
                    .shadow(color: Color.black.opacity(0.50), radius: 1.5, x: 0, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 8)
    }

    // MARK: 悬停迷你切歌条
    private var hoverControlsBar: some View {
        HStack(spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
                Button(action: { SpotifyController.shared.previous() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: { SpotifyController.shared.playPause() }) {
                    Image(systemName: vm.isPlayingState ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button(action: { SpotifyController.shared.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(.trailing, 12)
        }
        .frame(maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8)
        .transition(.opacity)
    }
}

// MARK: - 10. 主应用控制器与状态栏菜单
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let vm = LyricViewModel()
    var timer: Timer?

    private var isMiniMode: Bool = false
    private var lastExpandedHeight: CGFloat = 160.0

    private var isClickThrough: Bool {
        get { UserDefaults.standard.bool(forKey: "isClickThrough") }
        set { UserDefaults.standard.set(newValue, forKey: "isClickThrough") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusBar()
        startTimer()
    }

    private func setupWindow() {
        var initialRect = NSRect(x: 0, y: 0, width: 560, height: 110)
        if let saved = UserDefaults.standard.string(forKey: "WindowFrame") {
            let r = NSRectFromString(saved)
            if r.width >= 260 && r.height >= 50 {
                initialRect = r
            }
        }

        window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        window.minSize = NSSize(width: 260, height: 50)
        window.maxSize = NSSize(width: 1800, height: 1200)

        if UserDefaults.standard.string(forKey: "WindowFrame") == nil, let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.origin.x + (screenFrame.width - 560) / 2
            let y = screenFrame.origin.y + 60
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.ignoresMouseEvents = isClickThrough

        let doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClickGesture.numberOfClicksRequired = 2

        let hostingView = NSHostingView(rootView: LyricFloatingView(vm: vm))
        hostingView.addGestureRecognizer(doubleClickGesture)

        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        vm.updateDimensions(width: window.frame.width, height: window.frame.height)
    }

    @objc func handleDoubleClick() {
        var frame = window.frame
        if !isMiniMode {
            lastExpandedHeight = max(90.0, frame.height)
            frame.origin.y += (frame.height - 56.0)
            frame.size.height = 56.0
            isMiniMode = true
        } else {
            frame.origin.y -= (lastExpandedHeight - 56.0)
            frame.size.height = lastExpandedHeight
            isMiniMode = false
        }
        window.setFrame(frame, display: true, animate: true)
        saveWindowState()
        vm.updateDimensions(width: frame.width, height: frame.height)
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowState()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowState()
        vm.updateDimensions(width: window.frame.width, height: window.frame.height)
    }

    private func saveWindowState() {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "WindowFrame")
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Spotify 歌词")
        }
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let count = RobustLyricsCache.shared.getCachedCount()
        let titleItem = NSMenuItem(title: "🎵 Spotify 歌词助手 V5.7", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "显示 / 隐藏 桌面歌词", action: #selector(toggleWindow), keyEquivalent: "h"))

        let clickThroughTitle = isClickThrough ? "✓ 鼠标点击穿透模式 (已开启)" : "开启鼠标点击穿透模式"
        let clickThroughItem = NSMenuItem(title: clickThroughTitle, action: #selector(toggleClickThrough), keyEquivalent: "p")
        menu.addItem(clickThroughItem)

        menu.addItem(NSMenuItem(title: "双击折叠/展开单行模式", action: #selector(handleDoubleClick), keyEquivalent: "m"))
        menu.addItem(NSMenuItem.separator())

        // 🎨 字体颜色与氛围主题子菜单
        let themeMenu = NSMenu()
        for t in LyricTheme.allCases {
            let item = NSMenuItem(title: (vm.theme == t ? "✓ " : "   ") + t.displayName, action: #selector(changeThemeAction(_:)), keyEquivalent: "")
            item.representedObject = t.rawValue
            themeMenu.addItem(item)
        }
        let themeParent = NSMenuItem(title: "🎨 字体颜色与视觉主题", action: nil, keyEquivalent: "")
        themeParent.submenu = themeMenu
        menu.addItem(themeParent)

        // 🔤 字体大小实时档位切换菜单
        let fontMenu = NSMenu()
        for opt in LyricFontSizeOption.allCases {
            let isSelected = abs(vm.userSelectedFontSize - opt.rawValue) < 1.0
            let item = NSMenuItem(title: (isSelected ? "✓ " : "   ") + opt.displayName, action: #selector(changeFontSizeAction(_:)), keyEquivalent: "")
            item.representedObject = NSNumber(value: opt.rawValue)
            fontMenu.addItem(item)
        }
        let fontParent = NSMenuItem(title: "🔤 字体大小与行数联动 (当前: \(Int(vm.userSelectedFontSize)) pt)", action: nil, keyEquivalent: "")
        fontParent.submenu = fontMenu
        menu.addItem(fontParent)

        // ⚡️ 节能背景模式切换
        let glassTitle = vm.isGlassDisabled ? "✓ 极致节能模式 (已停用桌面毛玻璃)" : "切换至极致节能背景 (停用桌面毛玻璃)"
        let glassItem = NSMenuItem(title: glassTitle, action: #selector(toggleGlassAction), keyEquivalent: "")
        menu.addItem(glassItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "🔄 强制重新拉取当前歌词", action: #selector(reloadLyrics), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "🗑 清除本地歌词缓存 (已缓存 \(count) 首)", action: #selector(clearLyricsCache), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重置窗口大小与居中", action: #selector(resetWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 SpotifyLyrics", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func changeFontSizeAction(_ sender: NSMenuItem) {
        if let num = sender.representedObject as? NSNumber {
            let sz = CGFloat(num.doubleValue)
            vm.setUserFontSize(sz)
            updateMenu()
        }
    }

    @objc func toggleGlassAction() {
        vm.toggleGlassMode()
        updateMenu()
    }

    @objc func changeThemeAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = LyricTheme(rawValue: raw) {
            vm.setTheme(t)
            updateMenu()
        }
    }

    @objc func clearLyricsCache() {
        RobustLyricsCache.shared.clearAll()
        updateMenu()
        vm.reloadCurrent()
    }

    @objc func toggleClickThrough() {
        isClickThrough.toggle()
        window.ignoresMouseEvents = isClickThrough
        updateMenu()
    }

    private func startTimer() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.vm.onTick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    @objc func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func reloadLyrics() {
        vm.reloadCurrent()
    }

    @objc func resetWindow() {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let w: CGFloat = 560
            let h: CGFloat = 110
            let x = screenFrame.origin.x + (screenFrame.width - w) / 2
            let y = screenFrame.origin.y + 60
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: true)
            isMiniMode = false
            saveWindowState()
            vm.updateDimensions(width: w, height: h)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
