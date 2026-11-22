import Cocoa
import SwiftUI
import CryptoKit
import UserNotifications
import AVFoundation
import CoreMedia

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
    case compact    = 18.0
    case small      = 24.0
    case standard   = 30.0
    case medium     = 38.0
    case large      = 48.0
    case xlarge     = 64.0
    case tvSmall    = 84.0
    case tvMedium   = 108.0
    case tvLarge    = 140.0
    case tvCinema   = 180.0

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .compact:  return "18 pt (精巧小字 · 容纳更多行)"
        case .small:    return "24 pt (适中小字 · 经典视野)"
        case .standard: return "30 pt (标准推荐 · 均衡呼吸)"
        case .medium:   return "38 pt (大字醒目 · 舒适观赏)"
        case .large:    return "48 pt (超大画卷 · 气势磅礴)"
        case .xlarge:   return "64 pt (巨幕海报 · 远距观赏)"
        case .tvSmall:  return "84 pt (电视小号 · 43-55寸 TV / 2米清晰)"
        case .tvMedium: return "108 pt (电视标准 · 55-75寸 TV / 3米舒适)"
        case .tvLarge:  return "140 pt (客厅巨幕 · 75-85寸 TV / 3-5米大字)"
        case .tvCinema: return "180 pt (影院狂欢 · 85寸+ TV / 投影巨幕)"
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

    func parseLRC(_ lrc: String, artist: String = "") -> [LyricLine] {
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

// MARK: - 7.5 双模播放源定义 (Spotify / 本地音乐)
enum PlaybackSource: String {
    case spotify
    case local
}

// MARK: - 8. 视图状态中心 (以用户选择字号为核心，联动高度自适应展开行数)
class LyricViewModel: ObservableObject {
    static weak var shared: LyricViewModel?

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
    @Published var isAlwaysOnTop: Bool = false
    @Published var playbackSource: PlaybackSource = .spotify

    var onToggleAlwaysOnTop: (() -> Void)?
    var onMinimizeWindow: (() -> Void)?
    var onCloseWindow: (() -> Void)?
    var onQuitApp: (() -> Void)?

    private var lastTrackKey: String = ""
    private var currentTitle: String = ""
    private var currentArtist: String = ""
    private var currentDuration: Double = 0.0
    private var requestToken: UUID = UUID()

    var currentTrackTitle: String { currentTitle }
    var currentTrackArtist: String { currentArtist }
    var currentTrackDurationSeconds: Double { currentDuration }

    private var basePosition: Double = 0
    private var baseMediaTime: Double = 0
    private var smoothedOffsetCorrection: Double = 0.0
    private var lastPollTime: Double = 0
    private var isPollingInProgress: Bool = false
    private var consecutivePauseCount: Int = 0

    private var currentWindowWidth: CGFloat = 560
    private var currentWindowHeight: CGFloat = 110

    init() {
        Self.shared = self
        let savedTheme = UserDefaults.standard.string(forKey: "LyricTheme") ?? LyricTheme.appleMusic.rawValue
        self.theme = LyricTheme(rawValue: savedTheme) ?? .appleMusic
        self.isGlassDisabled = UserDefaults.standard.bool(forKey: "isGlassDisabled")
        let savedFont = UserDefaults.standard.double(forKey: "UserSelectedFontSize")
        self.userSelectedFontSize = savedFont >= 16.0 ? CGFloat(savedFont) : 30.0
        self.mainFontSize = self.userSelectedFontSize
        self.isAlwaysOnTop = UserDefaults.standard.bool(forKey: "isAlwaysOnTop")

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
            guard let self = self else { return }
            if !LocalMusicPlayer.shared.isPlaying {
                self.playbackSource = .spotify
            }
            self.consecutivePauseCount = 0
            self.pollSpotify(forceSync: true)
        }
    }

    func onTick() {
        if playbackSource == .local {
            let player = LocalMusicPlayer.shared
            self.isPlayingState = player.isPlaying
            if player.isPlaying {
                updateLyricsPosition(pos: player.currentTime)
            }
        } else {
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
    }

    func seekToLine(time: Double) {
        guard time >= 0 else { return }
        if playbackSource == .local {
            LocalMusicPlayer.shared.seek(to: time)
            updateLyricsPosition(pos: time)
        } else {
            SpotifyController.shared.seek(to: time)
            basePosition = time
            baseMediaTime = CACurrentMediaTime()
            smoothedOffsetCorrection = 0.0
            updateLyricsPosition(pos: time)
        }
    }

    func reloadCurrent() {
        if playbackSource == .local {
            if let cur = LocalMusicPlayer.shared.currentTrack {
                playLocalTrack(cur)
            }
        } else {
            guard !currentTitle.isEmpty else { return }
            lastTrackKey = ""
            isShowingLyrics = false
            placeholderTitle = "🔄 重新检索中..."
            placeholderSubtitle = "\(currentTitle) - \(currentArtist)"
            pollSpotify(forceSync: true, forceRefreshNetwork: true)
        }
    }

    func switchToSpotify() {
        if playbackSource == .local {
            LocalMusicPlayer.shared.pause()
        }
        self.playbackSource = .spotify
        self.lastTrackKey = ""
        self.isShowingLyrics = false
        self.placeholderTitle = "🎵 正在连接 Spotify..."
        self.placeholderSubtitle = "请在 Spotify 播放歌曲"
        pollSpotify(forceSync: true)
    }

    func playLocalTrack(_ track: LocalTrackItem) {
        self.playbackSource = .local
        self.currentTitle = track.title
        self.currentArtist = track.artist
        self.isPlayingState = true
        self.lastTrackKey = "LOCAL-\(track.artist)-\(track.title)"
        self.lyrics = []
        self.currentIndex = -1
        self.isShowingLyrics = false
        self.placeholderTitle = "🎵 \(track.title)"
        self.placeholderSubtitle = "\(track.artist) · 加载本地歌词..."

        let lrcURL = track.lrcURL ?? track.url.deletingPathExtension().appendingPathExtension("lrc")

        // 步骤一：优先读取本地同名 .lrc 文件
        if FileManager.default.fileExists(atPath: lrcURL.path),
           let lrcContent = try? String(contentsOf: lrcURL, encoding: .utf8),
           !lrcContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = LyricsEngine.shared.parseLRC(lrcContent, artist: track.artist)
            if !lines.isEmpty {
                self.lyrics = lines
                self.isShowingLyrics = true
                self.updateLyricsPosition(pos: LocalMusicPlayer.shared.currentTime)
                return
            }
        }

        // 步骤二：若无本地歌词，自动无感触发全网检索拉取并写入本地 .lrc
        self.placeholderSubtitle = "\(track.artist) · 正在联网匹配歌词..."
        let durationMs = track.duration > 0 ? (track.duration * 1000.0) : 0.0
        let currentToken = UUID()
        self.requestToken = currentToken

        LyricsEngine.shared.fetchLyrics(title: track.title, artist: track.artist, durationMs: durationMs) { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.requestToken == currentToken else { return }

                if let list = list, !list.isEmpty {
                    self.lyrics = list
                    self.isShowingLyrics = true
                    self.updateLyricsPosition(pos: LocalMusicPlayer.shared.currentTime)

                    // 将获取到的歌词写入同目录下的同名 .lrc
                    var reconstructed = ""
                    if !track.title.isEmpty { reconstructed += "[ti:\(track.title)]\n" }
                    if !track.artist.isEmpty { reconstructed += "[ar:\(track.artist)]\n" }
                    for l in list {
                        let m = Int(l.time) / 60
                        let s = l.time.truncatingRemainder(dividingBy: 60)
                        reconstructed += String(format: "[%02d:%05.2f]%@\n", m, s, l.text)
                    }
                    do {
                        try reconstructed.write(to: lrcURL, atomically: true, encoding: .utf8)
                        LocalMusicLibrary.shared.markTrackHasLrc(trackId: track.id, lrcURL: lrcURL)
                    } catch {
                        print("写入本地 LRC 失败: \(error)")
                    }
                } else {
                    self.placeholderTitle = "🎵 \(track.title)"
                    self.placeholderSubtitle = "\(track.artist) (全网检索完毕，暂无匹配歌词)"
                }
            }
        }
    }

    func updateDimensions(width: CGFloat, height: CGFloat) {
        self.currentWindowWidth = width
        self.currentWindowHeight = height
        recomputeFontAndLines()
    }

    // 【核心算法重构】：字号随用户设置生效 + 覆盖从桌面到电视巨幕 + 高度拉大后自适应铺满更多行数
    private func recomputeFontAndLines() {
        let height = currentWindowHeight
        let baseSize = userSelectedFontSize

        if height < 75 {
            // 单行迷你胶囊模式
            self.displayLineCount = 1
            self.mainFontSize = min(baseSize * 1.15, height * 0.65)
            return
        }

        // 黄金行高槽位：大字号(电视模式)紧凑高效以容纳更大字，普通字号保持舒适间距
        let slotFactor: CGFloat = baseSize >= 80.0 ? 1.35 : 1.48
        let slotHeight = baseSize * slotFactor
        let rawCount = Int(height / slotHeight)

        let targetLines: Int
        if rawCount <= 1 {
            // 高度不足以舒适容纳多行时，自动退化为单行超大字巨幕模式
            targetLines = 1
        } else {
            // 保证奇数行居中呈现 (3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25)
            let oddCount = (rawCount % 2 == 1) ? rawCount : (rawCount - 1)
            targetLines = max(3, min(oddCount, 25))
        }

        // 真实行高
        let actualRowHeight = height / CGFloat(targetLines)
        // 字号严格以用户选择的 baseSize 为主导
        let heightFactor: CGFloat = (targetLines == 1) ? 0.76 : 0.72
        let finalSize = min(baseSize, actualRowHeight * heightFactor)

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
                    self.currentDuration = state.durMs / 1000.0
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

    // MARK: 悬停迷你控制条 (支持置顶切换、切歌控制；最小化与关闭使用系统快捷键 ⌘M/⌘W 及右键菜单)
    private var hoverControlsBar: some View {
        HStack(spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
                // 窗口置顶切换 (图钉)
                Button(action: { vm.onToggleAlwaysOnTop?() }) {
                    Image(systemName: vm.isAlwaysOnTop ? "pin.fill" : "pin.slash")
                        .font(.system(size: 11))
                        .foregroundColor(vm.isAlwaysOnTop ? Color.yellow.opacity(0.95) : Color.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help(vm.isAlwaysOnTop ? "当前：永远置顶 (点击取消置顶)" : "当前：普通层级 (点击开启置顶)")

                // 分隔点
                Circle()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: 3, height: 3)

                Button(action: {
                    if vm.playbackSource == .local {
                        LocalMusicPlayer.shared.previous()
                    } else {
                        SpotifyController.shared.previous()
                    }
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: {
                    if vm.playbackSource == .local {
                        LocalMusicPlayer.shared.togglePlayPause()
                    } else {
                        SpotifyController.shared.playPause()
                    }
                }) {
                    Image(systemName: vm.isPlayingState ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button(action: {
                    if vm.playbackSource == .local {
                        LocalMusicPlayer.shared.next()
                    } else {
                        SpotifyController.shared.next()
                    }
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.60)))
            .padding(.trailing, 12)
        }
        .frame(maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8)
        .transition(.opacity)
    }
}

// MARK: - 10.5 本地音频引擎与本地曲库 (Local Music Player & Library)

struct LocalTrackItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let duration: Double // 单位：秒
    var hasLrc: Bool
    var lrcURL: URL?

    var formattedDuration: String {
        guard duration > 0, !duration.isNaN, !duration.isInfinite else { return "00:00" }
        let total = Int(duration)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

class LocalMusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = LocalMusicPlayer()

    @Published var isPlaying: Bool = false
    @Published var currentTrack: LocalTrackItem? = nil
    @Published var currentTrackIndex: Int = -1
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var playlist: [LocalTrackItem] = []
    @Published var isSingleLoop: Bool = false
    @Published var volume: Float = 1.0 {
        didSet {
            audioPlayer?.volume = volume
        }
    }

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    override init() {
        super.init()
    }

    func playTrack(_ track: LocalTrackItem, in list: [LocalTrackItem]? = nil) {
        if let list = list, !list.isEmpty {
            self.playlist = list
            if let idx = list.firstIndex(where: { $0.url == track.url }) {
                self.currentTrackIndex = idx
            } else {
                self.currentTrackIndex = -1
            }
        } else if let idx = playlist.firstIndex(where: { $0.url == track.url }) {
            self.currentTrackIndex = idx
        }

        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: track.url)
            audioPlayer?.delegate = self
            audioPlayer?.volume = volume
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            self.currentTrack = track
            self.isPlaying = true
            self.currentTime = 0.0
            self.duration = audioPlayer?.duration ?? track.duration

            startProgressTimer()

            DispatchQueue.main.async {
                LyricViewModel.shared?.playLocalTrack(track)
            }
        } catch {
            print("播放本地音频失败: \(error)")
            showSystemBanner(title: "播放本地音频失败", informativeText: "无法播放 \(track.title): \(error.localizedDescription)")
        }
    }

    func play() {
        guard let ap = audioPlayer else {
            if let track = currentTrack ?? playlist.first {
                playTrack(track)
            }
            return
        }
        ap.play()
        self.isPlaying = true
        startProgressTimer()
        LyricViewModel.shared?.isPlayingState = true
    }

    func pause() {
        audioPlayer?.pause()
        self.isPlaying = false
        stopProgressTimer()
        LyricViewModel.shared?.isPlayingState = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func previous() {
        guard !playlist.isEmpty else { return }
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }
        var nextIdx = currentTrackIndex - 1
        if nextIdx < 0 {
            nextIdx = playlist.count - 1
        }
        playTrack(playlist[nextIdx])
    }

    func next() {
        guard !playlist.isEmpty else { return }
        let nextIdx = (currentTrackIndex + 1) % playlist.count
        playTrack(playlist[nextIdx])
    }

    func seek(to time: Double) {
        guard let ap = audioPlayer else { return }
        let target = max(0, min(time, ap.duration))
        ap.currentTime = target
        self.currentTime = target
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let ap = self.audioPlayer else { return }
            self.currentTime = ap.currentTime
            if ap.duration > 0 {
                self.duration = ap.duration
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.progressTimer = t
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // AVAudioPlayerDelegate 回调：单曲/列表循环
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isSingleLoop, let cur = self.currentTrack {
                self.playTrack(cur)
            } else {
                self.next()
            }
        }
    }
}

class LocalMusicLibrary: NSObject, ObservableObject {
    static let shared = LocalMusicLibrary()

    private let userDefaultsKey = "UserLocalMusicDirectory"

    @Published var musicDirectoryURL: URL {
        didSet {
            UserDefaults.standard.set(musicDirectoryURL.path, forKey: userDefaultsKey)
        }
    }

    @Published var tracks: [LocalTrackItem] = []
    @Published var isScanning: Bool = false

    var musicDirectoryPath: String {
        musicDirectoryURL.path
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if musicDirectoryPath.hasPrefix(home) {
            return musicDirectoryPath.replacingOccurrences(of: home, with: "~")
        }
        return musicDirectoryPath
    }

    override init() {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), !saved.isEmpty {
            self.musicDirectoryURL = URL(fileURLWithPath: saved)
        } else if let downloadSaved = UserDefaults.standard.string(forKey: "UserDownloadDirectory"), !downloadSaved.isEmpty {
            self.musicDirectoryURL = URL(fileURLWithPath: downloadSaved)
        } else {
            let defaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
                .appendingPathComponent("Music")
            self.musicDirectoryURL = defaultDir
        }
        super.init()
        ensureDirectoryExists()
        scanTracks()
    }

    func ensureDirectoryExists() {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: musicDirectoryURL.path, isDirectory: &isDir) || !isDir.boolValue {
            try? FileManager.default.createDirectory(at: musicDirectoryURL, withIntermediateDirectories: true)
        }
    }

    func selectDirectory(window: NSWindow? = nil, completion: ((URL?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择音乐目录"
        panel.message = "请选择本地音乐文件夹"

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let selectedURL = panel.url {
                self?.musicDirectoryURL = selectedURL
                self?.ensureDirectoryExists()
                self?.scanTracks()
                completion?(selectedURL)
            } else {
                completion?(nil)
            }
        }

        if let win = window {
            panel.beginSheetModal(for: win, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func openInFinder() {
        ensureDirectoryExists()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: musicDirectoryURL.path)
    }

    func scanTracks() {
        ensureDirectoryExists()
        isScanning = true

        let folderURL = self.musicDirectoryURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            var items: [LocalTrackItem] = []
            let supportedExts = Set(["mp3", "flac", "m4a", "wav", "aac"])

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard supportedExts.contains(ext) else { continue }

                let baseName = fileURL.deletingPathExtension().lastPathComponent
                var title = baseName
                var artist = "未知歌手"

                if baseName.contains(" - ") {
                    let parts = baseName.components(separatedBy: " - ")
                    if parts.count >= 2 {
                        title = parts[0].trimmingCharacters(in: .whitespaces)
                        artist = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }

                let asset = AVURLAsset(url: fileURL)
                let dur = CMTimeGetSeconds(asset.duration)
                let finalDur = (dur.isNaN || dur.isInfinite || dur < 0) ? 0.0 : dur

                for meta in asset.commonMetadata {
                    if let key = meta.commonKey?.rawValue {
                        let stringVal = meta.value as? String
                        if key == "title", let v = stringVal, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                            title = v.trimmingCharacters(in: .whitespaces)
                        } else if key == "artist", let v = stringVal, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                            artist = v.trimmingCharacters(in: .whitespaces)
                        }
                    }
                }

                let lrcURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
                let hasLrc = fm.fileExists(atPath: lrcURL.path)

                let item = LocalTrackItem(
                    id: UUID(),
                    url: fileURL,
                    title: title,
                    artist: artist,
                    duration: finalDur,
                    hasLrc: hasLrc,
                    lrcURL: hasLrc ? lrcURL : nil
                )
                items.append(item)
            }

            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

            DispatchQueue.main.async {
                self.tracks = items
                self.isScanning = false
                if LocalMusicPlayer.shared.playlist.isEmpty && !items.isEmpty {
                    LocalMusicPlayer.shared.playlist = items
                }
            }
        }
    }

    func markTrackHasLrc(trackId: UUID, lrcURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.tracks.firstIndex(where: { $0.id == trackId }) {
                self.tracks[idx].hasLrc = true
                self.tracks[idx].lrcURL = lrcURL
            }
        }
    }
}

// MARK: - 11. 下载目录管理与配置中枢 (DownloadConfig)
class DownloadConfig: ObservableObject {
    static let shared = DownloadConfig()
    
    private let userDefaultsKey = "UserDownloadDirectory"
    private let customApiUrlKey = "UserCustomApiUrl"
    
    @Published var downloadDirectoryURL: URL {
        didSet {
            UserDefaults.standard.set(downloadDirectoryURL.path, forKey: userDefaultsKey)
        }
    }
    
    @Published var customApiUrl: String? {
        didSet {
            UserDefaults.standard.set(customApiUrl, forKey: customApiUrlKey)
        }
    }
    
    var downloadDirectoryPath: String {
        downloadDirectoryURL.path
    }
    
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if downloadDirectoryPath.hasPrefix(home) {
            return downloadDirectoryPath.replacingOccurrences(of: home, with: "~")
        }
        return downloadDirectoryPath
    }
    
    init() {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), !saved.isEmpty {
            self.downloadDirectoryURL = URL(fileURLWithPath: saved)
        } else {
            let defaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
                .appendingPathComponent("Music")
            self.downloadDirectoryURL = defaultDir
        }
        self.customApiUrl = UserDefaults.standard.string(forKey: customApiUrlKey)
        ensureDirectoryExists()
    }
    
    func ensureDirectoryExists() {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: downloadDirectoryURL.path, isDirectory: &isDir) || !isDir.boolValue {
            try? FileManager.default.createDirectory(at: downloadDirectoryURL, withIntermediateDirectories: true)
        }
    }
    
    func selectDirectory(window: NSWindow? = nil, completion: ((URL?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择目录"
        panel.message = "请选择音乐与歌词下载保存目录"
        
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let selectedURL = panel.url {
                self?.downloadDirectoryURL = selectedURL
                self?.ensureDirectoryExists()
                completion?(selectedURL)
            } else {
                completion?(nil)
            }
        }
        
        if let win = window {
            panel.beginSheetModal(for: win, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
    
    func openInFinder() {
        ensureDirectoryExists()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: downloadDirectoryURL.path)
    }
    
    static func cleanFileName(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?*\"<>|")
        var cleaned = string.components(separatedBy: invalidCharacters).joined(separator: "_")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = "Unknown"
        }
        return cleaned
    }
}

// 统一系统原生横幅通知分发
func showSystemBanner(title: String, informativeText: String) {
    if #available(macOS 10.14, *), let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = informativeText
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    } else if let notifClass = NSClassFromString("NSUserNotification") as? NSObject.Type,
              let centerClass = NSClassFromString("NSUserNotificationCenter") as? NSObject.Type {
        let notif = notifClass.init()
        notif.setValue(title, forKey: "title")
        notif.setValue(informativeText, forKey: "informativeText")
        if let defaultCenter = centerClass.value(forKey: "defaultUserNotificationCenter") as? NSObject {
            defaultCenter.perform(NSSelectorFromString("deliverNotification:"), with: notif)
        }
    }
}

// MARK: - 12. 全网四维多源聚合搜索与分布式跨平台直链下载引擎 (SongDownloadEngine)

// MARK: - 12.0 音乐来源平台枚举 (MusicSourcePlatform)
enum MusicSourcePlatform: String, CaseIterable, Identifiable {
    case all = "全部"
    case netease = "网易云"
    case kugou = "酷狗"
    case kuwo = "酷我"
    case qq = "QQ音乐"
    
    var id: String { rawValue }
    
    var badgeShortTitle: String {
        switch self {
        case .all: return "全部"
        case .netease: return "网易"
        case .kugou: return "酷狗"
        case .kuwo: return "酷我"
        case .qq: return "QQ"
        }
    }
    
    var badgeColor: Color {
        switch self {
        case .all:
            return Color.gray
        case .netease:
            return Color(red: 0.90, green: 0.22, blue: 0.21) // 红色
        case .kugou:
            return Color(red: 0.12, green: 0.53, blue: 0.90) // 蓝色
        case .kuwo:
            return Color(red: 0.95, green: 0.60, blue: 0.15) // 橙色
        case .qq:
            return Color(red: 0.18, green: 0.80, blue: 0.44) // 绿色
        }
    }
}

// MARK: - 12.0 多源聚合曲目数据模型 (SearchTrackItem)
struct SearchTrackItem: Identifiable, Equatable {
    let id: String // 跨平台唯一标识 (例如 netease_123, kugou_hash, kuwo_rid, qq_mid)
    let numericId: Int
    let source: MusicSourcePlatform
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Double
    let qualityTag: String // "FLAC" / "320K" / "192K" / "128K"
    let extraData: [String: String] // 存放 hash, album_id, rid, songmid 等解析参数
    
    var formattedDuration: String {
        let m = Int(durationSeconds) / 60
        let s = Int(durationSeconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 12.1 三维置信度评分与歌手白名单匹配器 (MultiFactorScorer)
struct MultiFactorScorer {
    // 负面噪音词表 (强力惩罚过滤)
    static let negativeKeywords: [String] = [
        "翻唱", "cover", "伴奏", "inst", "instrumental",
        "dj版", "dj", "remix", "纯音乐", "钢琴版", "吉他版"
    ]
    
    // 清洗歌手名，去除括号、feat、ft、with、特殊标点，转简体与小写
    static func normalizeArtist(_ raw: String) -> String {
        var s = toSimplified(raw).lowercased()
        let patterns = [
            "\\(.*?\\)",
            "\\[.*?\\]",
            "（.*?）",
            "【.*?】",
            "\\s*-\\s*.*",
            "\\b(feat\\.|ft\\.|with)\\b.*"
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                s = regex.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            }
        }
        let removeChars = CharacterSet(charactersIn: ",/&、|·•-_.()'\"[]")
        let parts = s.components(separatedBy: removeChars)
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // 清洗曲名，转简体与小写
    static func normalizeTitle(_ raw: String) -> String {
        let clean = cleanTrackTitle(raw)
        return toSimplified(clean).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // 提取子歌手清单 (支持多歌手逗号、/、&、;)
    static func extractSubArtists(_ raw: String) -> [String] {
        let seps = CharacterSet(charactersIn: ",/&、|;")
        let subRaw = raw.components(separatedBy: seps)
        var list: [String] = []
        for s in subRaw {
            let norm = normalizeArtist(s)
            if !norm.isEmpty {
                list.append(norm)
            }
        }
        return list
    }
    
    // 歌手一票否决与得分计算 (满分 50 分，不匹配返回 -999.0)
    static func computeArtistScore(candArtist: String, targetArtist: String) -> Double {
        let normTarget = normalizeArtist(targetArtist)
        let normCand = normalizeArtist(candArtist)
        
        guard !normTarget.isEmpty, !normCand.isEmpty else {
            return 0.0
        }
        
        // 排除“翻唱/cover”潜伏在歌手名中的情况 (如“周杰伦翻唱”或“网络翻唱”)
        let candLower = candArtist.lowercased()
        let targetLower = targetArtist.lowercased()
        if (candLower.contains("翻唱") || candLower.contains("cover")) &&
            (!targetLower.contains("翻唱") && !targetLower.contains("cover")) {
            return -999.0 // 一票否决
        }
        
        if normCand == normTarget {
            return 50.0
        }
        
        let targetSubs = extractSubArtists(targetArtist)
        let candSubs = extractSubArtists(candArtist)
        
        var isIncluded = false
        // 1. 整串包含判定 (如 "周杰伦, 阿信" 包含 "周杰伦")
        if normCand.contains(normTarget) {
            isIncluded = true
        } else if normTarget.contains(normCand) && normCand.count >= 2 {
            isIncluded = true
        } else {
            // 2. 子歌手分词交叉判定
            for t in targetSubs {
                guard t.count >= 2 else { continue }
                for c in candSubs {
                    guard c.count >= 2 else { continue }
                    if c == t || c.contains(t) || t.contains(c) {
                        isIncluded = true
                        break
                    }
                }
                if isIncluded { break }
            }
        }
        
        // 白名单一票否决制：非目标歌手直接剔除
        if !isIncluded {
            return -999.0
        }
        
        return 50.0
    }
    
    // 歌名匹配与负面标签过滤 (满分 30 分)
    static func computeTitleScore(candTitle: String, candArtist: String, candAlbum: String, targetTitle: String, targetArtist: String) -> Double {
        let normTarget = normalizeTitle(targetTitle)
        let normCand = normalizeTitle(candTitle)
        
        var score: Double = 0.0
        if normCand == normTarget {
            score = 30.0
        } else if normCand.contains(normTarget) || normTarget.contains(normCand) {
            score = 20.0
        } else {
            score = 5.0
        }
        
        // 负面词过滤：对包含 ['翻唱', 'cover', '伴奏', 'inst', 'instrumental', 'dj版', 'remix', '纯音乐', '钢琴版'] 等词汇强力惩罚扣分
        let targetFull = (targetTitle + " " + targetArtist).lowercased()
        let candFull = (candTitle + " " + candArtist + " " + candAlbum).lowercased()
        
        for kw in negativeKeywords {
            let kwSimp = toSimplified(kw).lowercased()
            if !targetFull.contains(kwSimp) && candFull.contains(kwSimp) {
                score -= 30.0
            }
        }
        
        return score
    }
    
    // 时长逼近评分 (满分 20 分)
    static func computeDurationScore(candDuration: Double, targetDuration: Double) -> Double {
        guard targetDuration > 15.0 else {
            return candDuration >= 60.0 ? 10.0 : -30.0
        }
        
        let diff = abs(candDuration - targetDuration)
        if diff <= 3.0 {
            return 20.0
        } else if diff <= 5.0 {
            return 15.0 // 偏差 <= 5s 加分
        } else if diff <= 8.0 {
            return 10.0
        } else if diff > 25.0 {
            return -30.0 // 偏差 > 25s 扣分
        } else {
            return max(0.0, 10.0 - (diff - 8.0) * 0.8)
        }
    }
    
    // 综合置信度评分计算
    static func scoreTrack(candidate: SearchTrackItem, targetTitle: String, targetArtist: String, targetDuration: Double) -> Double {
        let aScore = computeArtistScore(candArtist: candidate.artist, targetArtist: targetArtist)
        if aScore <= -900.0 {
            return -999.0 // 歌手一票否决
        }
        
        let tScore = computeTitleScore(candTitle: candidate.title, candArtist: candidate.artist, candAlbum: candidate.album, targetTitle: targetTitle, targetArtist: targetArtist)
        let dScore = computeDurationScore(candDuration: candidate.durationSeconds, targetDuration: targetDuration)
        
        var qBonus = 0.0
        if candidate.qualityTag == "FLAC" {
            qBonus = 5.0
        } else if candidate.qualityTag == "320K" {
            qBonus = 2.0
        }
        
        return aScore + tScore + dScore + qBonus
    }
    
    // 候选曲目过滤并按高置信度从高到低排序
    static func rankCandidates(candidates: [SearchTrackItem], targetTitle: String, targetArtist: String, targetDuration: Double) -> [SearchTrackItem] {
        var scored: [(item: SearchTrackItem, score: Double)] = []
        
        for c in candidates {
            let s = scoreTrack(candidate: c, targetTitle: targetTitle, targetArtist: targetArtist, targetDuration: targetDuration)
            if s > -900.0 {
                scored.append((c, s))
            }
        }
        
        let sorted = scored.sorted { $0.score > $1.score }
        
        // 门槛过滤：优先取 >= 50 分的高置信度曲目
        let highConf = sorted.filter { $0.score >= 50.0 }.map { $0.item }
        if !highConf.isEmpty {
            return highConf
        }
        
        // 降级兜底：通过歌手白名单且总分 > 0 的有效备选
        return sorted.filter { $0.score > 0 }.map { $0.item }
    }
}

// MARK: - 12.2 防试听物理时长门禁 (AntiPreviewGate)
struct AntiPreviewGate {
    enum GateResult {
        case pass(actualSeconds: Double)
        case fail(reason: String, actualSeconds: Double)
    }
    
    static func inspectAudio(at fileURL: URL, targetDuration: Double) -> GateResult {
        let asset = AVURLAsset(url: fileURL)
        let dur = CMTimeGetSeconds(asset.duration)
        
        // 防御 NaN、无穷大或异常值
        guard !dur.isNaN, !dur.isInfinite, dur > 0 else {
            return .fail(reason: "未能读取到有效音频音轨时长", actualSeconds: 0)
        }
        
        // 门禁规则 1: 绝对下限 >= 60.0 秒 (彻底拦截 15s/30s 试听片段)
        if dur < 60.0 {
            return .fail(reason: "音频物理时长仅 \(String(format: "%.1f", dur))s (< 60s)，判定为 VIP 试听残卷", actualSeconds: dur)
        }
        
        // 门禁规则 2: 若已知目标时长 (targetDuration > 30.0)，比对合理偏差
        if targetDuration > 30.0 {
            let diff = abs(dur - targetDuration)
            let ratio = dur / targetDuration
            // 相对容差: 误差 <= 18.0 秒，或时长比率在 85% ~ 115% 之间
            if diff > 18.0 && (ratio < 0.85 || ratio > 1.15) {
                return .fail(reason: "音频物理时长 \(String(format: "%.1f", dur))s 与目标时长 \(String(format: "%.1f", targetDuration))s 偏差过大 (差值: \(String(format: "%.1f", diff))s)", actualSeconds: dur)
            }
        }
        
        return .pass(actualSeconds: dur)
    }
}

enum TrackDownloadStatus: Equatable {
    case idle
    case downloading(progressText: String)
    case completed
    case failed(error: String)
}

// MARK: - 12.3 全网四维多源下载引擎实现
class SongDownloadEngine: ObservableObject {
    static let shared = SongDownloadEngine()
    
    // 键统一升级为 String，杜绝跨平台 id 类型冲突
    @Published var activeDownloads: [String: TrackDownloadStatus] = [:]
    
    // MARK: - 四维多源并发聚合搜索 (网易云 + 酷狗 + 酷我 + QQ音乐)
    func searchTracks(query: String, completion: @escaping ([SearchTrackItem]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        
        let group = DispatchGroup()
        let lock = NSLock()
        var allResults: [SearchTrackItem] = []
        
        // 1. 网易云
        group.enter()
        searchNetease(query: trimmed) { items in
            lock.lock()
            allResults.append(contentsOf: items)
            lock.unlock()
            group.leave()
        }
        
        // 2. 酷狗
        group.enter()
        searchKugou(query: trimmed) { items in
            lock.lock()
            allResults.append(contentsOf: items)
            lock.unlock()
            group.leave()
        }
        
        // 3. 酷我
        group.enter()
        searchKuwo(query: trimmed) { items in
            lock.lock()
            allResults.append(contentsOf: items)
            lock.unlock()
            group.leave()
        }
        
        // 4. QQ音乐
        group.enter()
        searchQQ(query: trimmed) { items in
            lock.lock()
            allResults.append(contentsOf: items)
            lock.unlock()
            group.leave()
        }
        
        // 超时控制 4.0s 并发聚合
        DispatchQueue.global(qos: .userInitiated).async {
            _ = group.wait(timeout: .now() + 4.0)
            
            lock.lock()
            let rawList = allResults
            lock.unlock()
            
            // 去重 (基于平台与 id)
            var seenIds = Set<String>()
            var uniqueItems: [SearchTrackItem] = []
            for item in rawList {
                if !seenIds.contains(item.id) {
                    seenIds.insert(item.id)
                    uniqueItems.append(item)
                }
            }
            
            // 按综合置信度与相关度排序
            let ranked = Self.rankSearchResults(items: uniqueItems, query: trimmed)
            
            DispatchQueue.main.async {
                completion(ranked)
            }
        }
    }
    
    // 搜索结果多维综合排序
    private static func rankSearchResults(items: [SearchTrackItem], query: String) -> [SearchTrackItem] {
        let cleanQ = toSimplified(cleanTrackTitle(query)).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return items.sorted { a, b in
            let scoreA = calculateItemSearchScore(item: a, cleanQuery: cleanQ)
            let scoreB = calculateItemSearchScore(item: b, cleanQuery: cleanQ)
            if scoreA != scoreB {
                return scoreA > scoreB
            }
            return a.durationSeconds > b.durationSeconds
        }
    }
    
    private static func calculateItemSearchScore(item: SearchTrackItem, cleanQuery: String) -> Double {
        var score: Double = 0.0
        let cleanTitle = toSimplified(cleanTrackTitle(item.title)).lowercased()
        let cleanArtist = toSimplified(MultiFactorScorer.normalizeArtist(item.artist)).lowercased()
        
        if cleanTitle == cleanQuery {
            score += 40.0
        } else if cleanTitle.contains(cleanQuery) {
            score += 25.0
        } else if cleanQuery.contains(cleanTitle) && cleanTitle.count >= 2 {
            score += 20.0
        }
        
        if cleanArtist == cleanQuery {
            score += 35.0
        } else if cleanArtist.contains(cleanQuery) {
            score += 20.0
        } else if cleanQuery.contains(cleanArtist) && cleanArtist.count >= 2 {
            score += 15.0
        }
        
        if (cleanTitle + " " + cleanArtist).contains(cleanQuery) {
            score += 10.0
        }
        
        if item.qualityTag == "FLAC" {
            score += 8.0
        } else if item.qualityTag == "320K" {
            score += 4.0
        }
        
        let fullText = (item.title + " " + item.artist + " " + item.album).lowercased()
        for kw in MultiFactorScorer.negativeKeywords {
            let kwSimp = toSimplified(kw).lowercased()
            if !cleanQuery.contains(kwSimp) && fullText.contains(kwSimp) {
                score -= 25.0
            }
        }
        
        return score
    }
    
    // MARK: - 源 1: 网易云检索
    private func searchNetease(query: String, completion: @escaping ([SearchTrackItem]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.163.com/api/cloudsearch/pc?s=\(encoded)&type=1&limit=15") else {
            completion([])
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 4.0
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]] else {
                completion([])
                return
            }
            
            var items: [SearchTrackItem] = []
            for s in songs {
                guard let id = s["id"] as? Int,
                      let name = s["name"] as? String else { continue }
                
                var artistName = "未知歌手"
                if let ars = s["ar"] as? [[String: Any]], !ars.isEmpty {
                    artistName = ars.compactMap { $0["name"] as? String }.joined(separator: ", ")
                } else if let ars = s["artists"] as? [[String: Any]], !ars.isEmpty {
                    artistName = ars.compactMap { $0["name"] as? String }.joined(separator: ", ")
                }
                
                let albumName = (s["al"] as? [String: Any])?["name"] as? String
                    ?? (s["album"] as? [String: Any])?["name"] as? String
                    ?? ""
                
                let dtMs = s["dt"] as? Double ?? (s["duration"] as? Double ?? 0.0)
                let durSec = dtMs / 1000.0
                
                var qualityTag = "320K"
                if s["hr"] != nil || s["sq"] != nil {
                    qualityTag = "FLAC"
                } else if let priv = s["privilege"] as? [String: Any], let maxbr = priv["maxbr"] as? Int, maxbr >= 999000 {
                    qualityTag = "FLAC"
                } else if s["h"] != nil {
                    qualityTag = "320K"
                } else if s["m"] != nil {
                    qualityTag = "192K"
                } else {
                    qualityTag = "128K"
                }
                
                items.append(SearchTrackItem(
                    id: "netease_\(id)",
                    numericId: id,
                    source: .netease,
                    title: name,
                    artist: artistName,
                    album: albumName,
                    durationSeconds: durSec,
                    qualityTag: qualityTag,
                    extraData: ["id": "\(id)"]
                ))
            }
            completion(items)
        }.resume()
    }
    
    // MARK: - 源 2: 酷狗检索
    private func searchKugou(query: String, completion: @escaping ([SearchTrackItem]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=\(encoded)&page=1&pagesize=15&showtype=1") else {
            completion([])
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 4.0
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let info = dataObj["info"] as? [[String: Any]] else {
                completion([])
                return
            }
            
            var items: [SearchTrackItem] = []
            for s in info {
                guard let hash = s["hash"] as? String, !hash.isEmpty else { continue }
                
                var songName = (s["songname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var singerName = (s["singername"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fileName = s["filename"] as? String ?? ""
                
                if songName.isEmpty && fileName.contains(" - ") {
                    let parts = fileName.components(separatedBy: " - ")
                    if parts.count >= 2 {
                        singerName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        songName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        songName = fileName
                    }
                }
                if singerName.isEmpty { singerName = "未知歌手" }
                if songName.isEmpty { songName = fileName.isEmpty ? "未知曲目" : fileName }
                
                let albumName = s["album_name"] as? String ?? ""
                let dur: Double = {
                    if let d = s["duration"] as? Double { return d }
                    if let i = s["duration"] as? Int { return Double(i) }
                    if let str = s["duration"] as? String, let val = Double(str) { return val }
                    return 0.0
                }()
                
                let sqHash = s["sqhash"] as? String ?? ""
                let h320Hash = s["320hash"] as? String ?? ""
                let qualityTag = !sqHash.isEmpty ? "FLAC" : (!h320Hash.isEmpty ? "320K" : "128K")
                
                let albumId: String
                if let aidStr = s["album_id"] as? String {
                    albumId = aidStr
                } else if let aidInt = s["album_id"] as? Int {
                    albumId = "\(aidInt)"
                } else {
                    albumId = ""
                }
                
                items.append(SearchTrackItem(
                    id: "kugou_\(hash)",
                    numericId: 0,
                    source: .kugou,
                    title: songName,
                    artist: singerName,
                    album: albumName,
                    durationSeconds: dur,
                    qualityTag: qualityTag,
                    extraData: ["hash": hash, "album_id": albumId, "sqhash": sqHash, "320hash": h320Hash]
                ))
            }
            completion(items)
        }.resume()
    }
    
    // MARK: - 源 3: 酷我检索
    private func searchKuwo(query: String, completion: @escaping ([SearchTrackItem]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://search.kuwo.cn/r.s?client=kt&all=\(encoded)&pn=0&rn=15&uid=794762528&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newsearch=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1") else {
            completion([])
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 4.0
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data else {
                completion([])
                return
            }
            
            let abslist: [[String: Any]]? = {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["abslist"] as? [[String: Any]] {
                    return list
                }
                if var text = String(data: data, encoding: .utf8) {
                    text = text.replacingOccurrences(of: "'", with: "\"")
                    if let cleanData = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: cleanData) as? [String: Any],
                       let list = json["abslist"] as? [[String: Any]] {
                        return list
                    }
                }
                return nil
            }()
            
            guard let abslist = abslist else {
                completion([])
                return
            }
            
            var items: [SearchTrackItem] = []
            for s in abslist {
                guard let rawRid = (s["MUSICRID"] as? String) ?? (s["musicrid"] as? String) else { continue }
                let rid = rawRid.replacingOccurrences(of: "MUSIC_", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rid.isEmpty else { continue }
                
                var songName = (s["SONGNAME"] as? String) ?? (s["name"] as? String) ?? "未知曲目"
                songName = songName.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                
                var artistName = (s["ARTIST"] as? String) ?? (s["artist"] as? String) ?? "未知歌手"
                artistName = artistName.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                
                var albumName = (s["ALBUM"] as? String) ?? (s["album"] as? String) ?? ""
                albumName = albumName.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                
                var durSec: Double = 0.0
                if let durInt = s["DURATION"] as? Int {
                    durSec = Double(durInt)
                } else if let durStr = s["DURATION"] as? String, let durVal = Double(durStr) {
                    durSec = durVal
                }
                
                let formats = ((s["FORMATS"] as? String) ?? "").uppercased()
                let qualityTag = formats.contains("FLAC") ? "FLAC" : (formats.contains("320") ? "320K" : "128K")
                
                let numId = Int(rid) ?? 0
                items.append(SearchTrackItem(
                    id: "kuwo_\(rid)",
                    numericId: numId,
                    source: .kuwo,
                    title: songName,
                    artist: artistName,
                    album: albumName,
                    durationSeconds: durSec,
                    qualityTag: qualityTag,
                    extraData: ["rid": rid]
                ))
            }
            completion(items)
        }.resume()
    }
    
    // MARK: - 源 4: QQ音乐检索
    private func searchQQ(query: String, completion: @escaping ([SearchTrackItem]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(encoded)&format=json&n=15") else {
            completion([])
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 4.0
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let songObj = dataObj["song"] as? [String: Any],
                  let songList = songObj["list"] as? [[String: Any]] else {
                completion([])
                return
            }
            
            var items: [SearchTrackItem] = []
            for s in songList {
                guard let songmid = s["songmid"] as? String, !songmid.isEmpty,
                      let songname = s["songname"] as? String else { continue }
                
                var artistName = "未知歌手"
                if let singers = s["singer"] as? [[String: Any]], !singers.isEmpty {
                    artistName = singers.compactMap { $0["name"] as? String }.joined(separator: ", ")
                }
                
                let albumname = s["albumname"] as? String ?? ""
                let interval: Double = {
                    if let d = s["interval"] as? Double { return d }
                    if let i = s["interval"] as? Int { return Double(i) }
                    if let str = s["interval"] as? String, let val = Double(str) { return val }
                    return 0.0
                }()
                
                let sizeflac = s["sizeflac"] as? Int ?? 0
                let size320 = s["size320"] as? Int ?? 0
                let qualityTag = sizeflac > 0 ? "FLAC" : (size320 > 0 ? "320K" : "128K")
                
                let songid = s["songid"] as? Int ?? 0
                
                items.append(SearchTrackItem(
                    id: "qq_\(songmid)",
                    numericId: songid,
                    source: .qq,
                    title: songname,
                    artist: artistName,
                    album: albumname,
                    durationSeconds: interval,
                    qualityTag: qualityTag,
                    extraData: ["songmid": songmid, "songid": "\(songid)"]
                ))
            }
            completion(items)
        }.resume()
    }
    
    // MARK: - 内部重定向捕获 Delegate
    private class RedirectCatchDelegate: NSObject, URLSessionTaskDelegate {
        var redirectedURLString: String?
        
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let location = response.allHeaderFields["Location"] as? String ?? response.allHeaderFields["location"] as? String {
                self.redirectedURLString = location
            } else if let url = request.url?.absoluteString {
                self.redirectedURLString = url
            }
            completionHandler(nil)
        }
    }
    
    // MARK: - Master Hi-Res 24bit 全曲音源直链通道
    func fetchMasterAudioUrl(title: String, artist: String, preferLossless: Bool = true, completion: @escaping (String?, String?) -> Void) {
        let cleanT = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanA = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryStr = cleanA.isEmpty ? cleanT : "\(cleanT) \(cleanA)"
        guard let encodedMsg = queryStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(nil, nil)
            return
        }
        
        let br = preferLossless ? 1 : 2
        let urlStr = "https://oiapi.net/api/Kuwo?msg=\(encodedMsg)&br=\(br)&n=1"
        guard let url = URL(string: urlStr) else {
            completion(nil, nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.5
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else {
                completion(nil, nil)
                return
            }
            
            var messageStr: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                messageStr = (json["message"] as? String) ?? (json["msg"] as? String) ?? (json["data"] as? String)
            }
            if messageStr == nil {
                messageStr = String(data: data, encoding: .utf8)
            }
            
            guard let message = messageStr else {
                completion(nil, nil)
                return
            }
            
            let pattern = "音乐链接：(\\S+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: message, options: [], range: NSRange(location: 0, length: message.utf16.count)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: message) else {
                completion(nil, nil)
                return
            }
            
            let directUrl = String(message[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard directUrl.hasPrefix("http") else {
                completion(nil, nil)
                return
            }
            
            let lower = directUrl.lowercased()
            let format: String
            if lower.contains(".flac") || lower.contains("format=flac") || lower.contains("flac") {
                format = "flac"
            } else if lower.contains(".ogg") || lower.contains("format=ogg") || lower.contains("ogg") {
                format = "ogg"
            } else if lower.contains(".mp3") || lower.contains("format=mp3") || lower.contains("mp3") {
                format = "mp3"
            } else {
                format = "mp3"
            }
            
            completion(directUrl, format)
        }.resume()
    }
    
    // MARK: - 分布式直链解析分发器 (Master Hi-Res 第一优先级 -> Custom API -> 平台内置分发)
    func fetchDirectAudioUrl(candidate: SearchTrackItem, completion: @escaping (String?, String?) -> Void) {
        // 1. 【第一优先级】优先调用 Master Hi-Res 24bit 全曲通道
        fetchMasterAudioUrl(title: candidate.title, artist: candidate.artist) { [weak self] masterUrl, masterFormat in
            guard let self = self else { return }
            if let masterUrl = masterUrl, !masterUrl.isEmpty {
                NSLog("[SongDownloadEngine] 🚀 命中 Master Hi-Res 直链通道 [\(masterFormat ?? "flac")]: \(candidate.title) - \(candidate.artist)")
                completion(masterUrl, masterFormat ?? "flac")
                return
            }
            
            // 2. Master 通道未命中或超时，平滑降级至自定义 API 节点
            if let customApi = DownloadConfig.shared.customApiUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !customApi.isEmpty {
                self.fetchFromCustomApi(customApi: customApi, candidate: candidate) { [weak self] directUrl, format in
                    if let directUrl = directUrl, !directUrl.isEmpty {
                        completion(directUrl, format ?? "mp3")
                    } else {
                        // 自定义 API 未命中或失败，平滑降级至平台内置解析通道
                        self?.fetchPlatformDirectUrl(candidate: candidate, completion: completion)
                    }
                }
                return
            }
            
            // 3. 平滑降级至现有 fetchPlatformDirectUrl 内置多平台通道
            self.fetchPlatformDirectUrl(candidate: candidate, completion: completion)
        }
    }
    
    private func fetchPlatformDirectUrl(candidate: SearchTrackItem, completion: @escaping (String?, String?) -> Void) {
        switch candidate.source {
        case .netease:
            fetchNeteaseAudioUrl(id: candidate.numericId, completion: completion)
        case .kuwo:
            fetchKuwoAudioUrl(candidate: candidate, completion: completion)
        case .kugou:
            fetchKugouAudioUrl(candidate: candidate, completion: completion)
        case .qq:
            fetchQQAudioUrl(candidate: candidate, completion: completion)
        case .all:
            completion(nil, nil)
        }
    }
    
    // 通用自定义 API 解析
    private func fetchFromCustomApi(customApi: String, candidate: SearchTrackItem, completion: @escaping (String?, String?) -> Void) {
        var targetUrlStr = customApi
        let encId = candidate.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encTitle = candidate.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encArtist = candidate.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if targetUrlStr.contains("{id}") || targetUrlStr.contains("{source}") {
            targetUrlStr = targetUrlStr
                .replacingOccurrences(of: "{id}", with: encId)
                .replacingOccurrences(of: "{numericId}", with: "\(candidate.numericId)")
                .replacingOccurrences(of: "{source}", with: candidate.source.rawValue)
                .replacingOccurrences(of: "{title}", with: encTitle)
                .replacingOccurrences(of: "{artist}", with: encArtist)
        } else {
            let sep = targetUrlStr.contains("?") ? "&" : "?"
            targetUrlStr = "\(targetUrlStr)\(sep)id=\(encId)&source=\(candidate.source.rawValue)&title=\(encTitle)&artist=\(encArtist)"
        }
        
        guard let url = URL(string: targetUrlStr) else {
            completion(nil, nil)
            return
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data else {
                completion(nil, nil)
                return
            }
            
            if let direct = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), direct.hasPrefix("http") {
                let ext = direct.lowercased().contains(".flac") ? "flac" : "mp3"
                completion(direct, ext)
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let urlStr = (json["url"] as? String)
                    ?? ((json["data"] as? [String: Any])?["url"] as? String)
                    ?? (json["data"] as? String)
                if let direct = urlStr, direct.hasPrefix("http") {
                    let ext = direct.lowercased().contains(".flac") ? "flac" : "mp3"
                    completion(direct, ext)
                    return
                }
            }
            completion(nil, nil)
        }.resume()
    }
    
    // 网易云直链 (三通道: Meting 302 -> Paugram -> Meting 直链跟随)
    private func fetchNeteaseAudioUrl(id: Int, completion: @escaping (String?, String?) -> Void) {
        if id <= 0 {
            completion(nil, nil)
            return
        }
        
        let metingUrlStr = "https://api.injahow.cn/meting/?type=url&id=\(id)"
        guard let metingUrl = URL(string: metingUrlStr) else {
            completion(nil, nil)
            return
        }
        
        let delegate = RedirectCatchDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var headReq = URLRequest(url: metingUrl)
        headReq.httpMethod = "HEAD"
        headReq.timeoutInterval = 4.0
        headReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        session.dataTask(with: headReq) { [weak self] _, resp, _ in
            guard let self = self else { return }
            
            let location = delegate.redirectedURLString
                ?? (resp as? HTTPURLResponse)?.allHeaderFields["Location"] as? String
                ?? (resp as? HTTPURLResponse)?.allHeaderFields["location"] as? String
            
            if let loc = location, !loc.isEmpty, !loc.contains("404"), loc.hasPrefix("http") {
                let ext = loc.lowercased().contains(".flac") ? "flac" : "mp3"
                completion(loc, ext)
                return
            }
            
            self.fetchPaugramAudioUrl(id: id) { paugramLink in
                if let link = paugramLink, !link.isEmpty, !link.contains("404"), link.hasPrefix("http") {
                    let ext = link.lowercased().contains(".flac") ? "flac" : "mp3"
                    completion(link, ext)
                    return
                }
                completion(metingUrlStr, "mp3")
            }
        }.resume()
    }
    
    private func fetchPaugramAudioUrl(id: Int, completion: @escaping (String?) -> Void) {
        guard let paugramUrl = URL(string: "https://api.paugram.com/netease/?id=\(id)") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: paugramUrl)
        req.timeoutInterval = 4.0
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let link = json["link"] as? String,
                  !link.isEmpty,
                  !link.contains("404"),
                  link.hasPrefix("http") else {
                completion(nil)
                return
            }
            completion(link)
        }.resume()
    }
    
    // 酷我直链解析 (Antiserver Convert URL)
    private func fetchKuwoAudioUrl(candidate: SearchTrackItem, completion: @escaping (String?, String?) -> Void) {
        let rid = candidate.extraData["rid"] ?? "\(candidate.numericId)"
        guard !rid.isEmpty, rid != "0" else {
            completion(nil, nil)
            return
        }
        
        let urlStr = "http://antiserver.kuwo.cn/anti.s?type=convert_url&rid=\(rid)&format=mp3&response=url"
        guard let url = URL(string: urlStr) else {
            completion(nil, nil)
            return
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data else {
                completion(nil, nil)
                return
            }
            
            if let direct = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), direct.hasPrefix("http") {
                let ext = direct.lowercased().contains(".flac") ? "flac" : "mp3"
                completion(direct, ext)
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let direct = json["url"] as? String, direct.hasPrefix("http") {
                let ext = direct.lowercased().contains(".flac") ? "flac" : "mp3"
                completion(direct, ext)
                return
            }
            
            completion(nil, nil)
        }.resume()
    }
    
    // 酷狗移动端直链解析
    private func fetchKugouAudioUrl(candidate: SearchTrackItem, completion: @escaping (String?, String?) -> Void) {
        let hash = candidate.extraData["hash"] ?? candidate.id.replacingOccurrences(of: "kugou_", with: "")
        guard !hash.isEmpty else {
            completion(nil, nil)
            return
        }
        
        let urlStr = "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=\(hash)"
        guard let url = URL(string: urlStr) else {
            completion(nil, nil)
            return
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let playUrl = json["url"] as? String, playUrl.hasPrefix("http"), !playUrl.isEmpty {
                    let ext = playUrl.lowercased().contains(".flac") ? "flac" : "mp3"
                    completion(playUrl, ext)
                    return
                }
                if let backups = json["backup_url"] as? [String], let first = backups.first, first.hasPrefix("http") {
                    let ext = first.lowercased().contains(".flac") ? "flac" : "mp3"
                    completion(first, ext)
                    return
                }
            }
            
            let albumId = candidate.extraData["album_id"] ?? ""
            self.fetchKugouWebPlayData(hash: hash, albumId: albumId, completion: completion)
        }.resume()
    }
    
    private func fetchKugouWebPlayData(hash: String, albumId: String, completion: @escaping (String?, String?) -> Void) {
        var comp = URLComponents(string: "http://www.kugou.com/yy/index.php")
        comp?.queryItems = [
            URLQueryItem(name: "r", value: "play/getdata"),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "album_id", value: albumId)
        ]
        guard let url = comp?.url else {
            completion(nil, nil)
            return
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("kg_mid=23333333333333333333333333333333", forHTTPHeaderField: "Cookie")
        
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any] else {
                completion(nil, nil)
                return
            }
            
            if let playUrl = dataObj["play_url"] as? String, playUrl.hasPrefix("http"), !playUrl.isEmpty {
                let ext = playUrl.lowercased().contains(".flac") ? "flac" : "mp3"
                completion(playUrl, ext)
                return
            }
            if let playBackup = dataObj["play_backup_url"] as? String, playBackup.hasPrefix("http"), !playBackup.isEmpty {
                let ext = playBackup.lowercased().contains(".flac") ? "flac" : "mp3"
                completion(playBackup, ext)
                return
            }
            
            completion(nil, nil)
        }.resume()
    }
    
    // QQ音乐直链解析
    private func fetchQQAudioUrl(candidate: SearchTrackItem, completion: @escaping (String?, String?) -> Void) {
        completion(nil, nil)
    }
    
    // MARK: - 单候选下载与物理时长门禁校验
    private func downloadSingleCandidate(
        candidate: SearchTrackItem,
        targetTitle: String,
        targetArtist: String,
        targetDuration: Double,
        uiTrackId: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        fetchDirectAudioUrl(candidate: candidate) { [weak self] audioUrlStr, formatType in
            guard let self = self else {
                completion(false, "实例已释放")
                return
            }
            
            guard let audioUrlStr = audioUrlStr, let audioDownloadUrl = URL(string: audioUrlStr) else {
                completion(false, "未能获取到 [\(candidate.source.rawValue)] 音频直链")
                return
            }
            
            let workingTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            var effectiveTempURL = workingTempURL
            var effectiveFormat = formatType
            var req = URLRequest(url: audioDownloadUrl)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 45.0
            
            let downloadTask = URLSession.shared.downloadTask(with: req) { tempURL, response, error in
                guard let tempURL = tempURL, error == nil else {
                    try? FileManager.default.removeItem(at: effectiveTempURL)
                    completion(false, error?.localizedDescription ?? "下载失败")
                    return
                }
                
                do {
                    if FileManager.default.fileExists(atPath: effectiveTempURL.path) {
                        try FileManager.default.removeItem(at: effectiveTempURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: effectiveTempURL)
                } catch {
                    try? FileManager.default.removeItem(at: effectiveTempURL)
                    completion(false, "临时文件移动失败")
                    return
                }
                
                // 1. 校验大小 > 100KB
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: effectiveTempURL.path)[.size] as? Int64) ?? 0
                guard fileSize > 100 * 1024 else {
                    try? FileManager.default.removeItem(at: effectiveTempURL)
                    completion(false, "音频文件过小 (<100KB)，判定为无效内容")
                    return
                }
                
                // 2. 格式自适应与 OGG 转码处理 (FFmpeg Pipeline)
                var isOgg = (effectiveFormat?.lowercased() == "ogg")
                if !isOgg, let handle = try? FileHandle(forReadingFrom: effectiveTempURL) {
                    let header = handle.readData(ofLength: 4)
                    try? handle.close()
                    if header.count >= 4 && header.starts(with: [0x4F, 0x67, 0x67, 0x53]) { // "OggS"
                        isOgg = true
                    }
                }
                
                if isOgg {
                    let ffmpegCandidates = [
                        "/opt/homebrew/bin/ffmpeg",
                        "/usr/local/bin/ffmpeg",
                        "/usr/bin/ffmpeg"
                    ]
                    if let ffmpegPath = ffmpegCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                        let convertedTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: ffmpegPath)
                        process.arguments = ["-y", "-i", effectiveTempURL.path, "-c:a", "libmp3lame", "-q:a", "0", convertedTempURL.path]
                        process.standardOutput = Pipe()
                        process.standardError = Pipe()
                        
                        do {
                            try process.run()
                            process.waitUntilExit()
                            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: convertedTempURL.path) {
                                try? FileManager.default.removeItem(at: effectiveTempURL)
                                effectiveTempURL = convertedTempURL
                                effectiveFormat = "mp3"
                                NSLog("[SongDownloadEngine] 🔄 OGG -> MP3 转码成功: \(effectiveTempURL.path)")
                            } else {
                                try? FileManager.default.removeItem(at: convertedTempURL)
                                NSLog("[SongDownloadEngine] ⚠️ ffmpeg 转码未正常退出 (code: \(process.terminationStatus))")
                            }
                        } catch {
                            try? FileManager.default.removeItem(at: convertedTempURL)
                            NSLog("[SongDownloadEngine] ⚠️ ffmpeg 执行异常: \(error)")
                        }
                    }
                }
                
                // 3. 物理时长门禁检查
                let effTargetDur = targetDuration > 0 ? targetDuration : candidate.durationSeconds
                let gateResult = AntiPreviewGate.inspectAudio(at: effectiveTempURL, targetDuration: effTargetDur)
                
                switch gateResult {
                case .fail(let reason, let actualSec):
                    // 门禁拦截！立即删除临时文件
                    try? FileManager.default.removeItem(at: effectiveTempURL)
                    NSLog("[AntiPreviewGate] 拦截候选 id=\(candidate.id) [\(candidate.source.rawValue)] (\(candidate.title) - \(candidate.artist)): \(reason)")
                    completion(false, "防试听门禁拦截: \(reason) (\(String(format: "%.1f", actualSec))s)")
                    
                case .pass(let actualSec):
                    // 门禁通过！判定为真实完整音频！
                    DownloadConfig.shared.ensureDirectoryExists()
                    let destDir = DownloadConfig.shared.downloadDirectoryURL
                    let ext = self.detectAudioExtension(fileURL: effectiveTempURL, response: response, fallbackFormat: effectiveFormat)
                    let finalTitle = targetTitle.isEmpty ? candidate.title : targetTitle
                    let finalArtist = targetArtist.isEmpty ? candidate.artist : targetArtist
                    let safeTitle = DownloadConfig.cleanFileName(finalTitle)
                    let safeArtist = DownloadConfig.cleanFileName(finalArtist)
                    let baseFileName = "\(safeTitle) - \(safeArtist)"
                    let audioDestURL = destDir.appendingPathComponent("\(baseFileName).\(ext)")
                    let lrcDestURL = destDir.appendingPathComponent("\(baseFileName).lrc")
                    
                    do {
                        if FileManager.default.fileExists(atPath: audioDestURL.path) {
                            try FileManager.default.removeItem(at: audioDestURL)
                        }
                        try FileManager.default.moveItem(at: effectiveTempURL, to: audioDestURL)
                    } catch {
                        try? FileManager.default.removeItem(at: effectiveTempURL)
                        completion(false, "目标文件写入失败: \(error.localizedDescription)")
                        return
                    }
                    
                    // 并发拉取并保存同名 LRC 歌词
                    self.fetchAndSaveLrc(candidate: candidate, title: finalTitle, artist: finalArtist, album: candidate.album, destURL: lrcDestURL) { _ in
                        DispatchQueue.main.async {
                            self.activeDownloads[uiTrackId] = .completed
                            self.notifyDownloadComplete(title: finalTitle, artist: finalArtist, audioURL: audioDestURL, lrcURL: lrcDestURL)
                            completion(true, "下载完成 (已通过时长门禁: \(String(format: "%.1f", actualSec))s)")
                        }
                    }
                }
            }
            downloadTask.resume()
        }
    }
    
    // MARK: - 跨平台换源轮询候选队列下载器
    private func downloadCandidateQueue(
        queue: [SearchTrackItem],
        index: Int,
        targetTitle: String,
        targetArtist: String,
        targetDuration: Double,
        uiTrackId: String,
        completion: ((Bool, String) -> Void)?
    ) {
        if index >= queue.count {
            // 全网多源候选均已尝试完毕，自动转入本地 yt-dlp 兜底
            let destDir = DownloadConfig.shared.downloadDirectoryURL
            let safeTitle = DownloadConfig.cleanFileName(targetTitle)
            let safeArtist = DownloadConfig.cleanFileName(targetArtist)
            let baseFileName = "\(safeTitle) - \(safeArtist)"
            let lrcDestURL = destDir.appendingPathComponent("\(baseFileName).lrc")
            
            fallbackWithYtDlp(title: targetTitle, artist: targetArtist, targetDuration: targetDuration, destDir: destDir, lrcDestURL: lrcDestURL, trackId: uiTrackId) { success, msg in
                if !success {
                    let failMsg = "全网多平台音源均为试听片段（或受版权限制），已拦截保存残卷"
                    DispatchQueue.main.async {
                        self.activeDownloads[uiTrackId] = .failed(error: failMsg)
                        completion?(false, failMsg)
                    }
                } else {
                    completion?(true, msg)
                }
            }
            return
        }
        
        let candidate = queue[index]
        let currentStep = index + 1
        let totalCount = queue.count
        
        DispatchQueue.main.async {
            self.activeDownloads[uiTrackId] = .downloading(progressText: "正在尝试第 \(currentStep)/\(totalCount) 个音源 [\(candidate.source.rawValue) - \(candidate.qualityTag)]...")
        }
        
        downloadSingleCandidate(candidate: candidate, targetTitle: targetTitle, targetArtist: targetArtist, targetDuration: targetDuration, uiTrackId: uiTrackId) { [weak self] success, msg in
            guard let self = self else { return }
            if success {
                completion?(true, msg)
            } else {
                // 当前源受限或被门禁拦截，自动跨平台无感尝试下一个音源！
                DispatchQueue.main.async {
                    self.activeDownloads[uiTrackId] = .downloading(progressText: "[\(candidate.source.rawValue)] 未通过门禁，正在跨平台换源重试...")
                }
                self.downloadCandidateQueue(queue: queue, index: index + 1, targetTitle: targetTitle, targetArtist: targetArtist, targetDuration: targetDuration, uiTrackId: uiTrackId, completion: completion)
            }
        }
    }
    
    // 下载曲目 (多平台分布式直链 + 防试听门禁 + 跨平台自动换源)
    func downloadTrack(item: SearchTrackItem, completion: ((Bool, String) -> Void)? = nil) {
        DownloadConfig.shared.ensureDirectoryExists()
        
        DispatchQueue.main.async {
            self.activeDownloads[item.id] = .downloading(progressText: "获取 [\(item.source.rawValue)] 最高音质链接...")
        }
        
        // 1. 首先以当前 item 作为首选尝试
        self.downloadSingleCandidate(candidate: item, targetTitle: item.title, targetArtist: item.artist, targetDuration: item.durationSeconds, uiTrackId: item.id) { [weak self] success, msg in
            guard let self = self else { return }
            if success {
                completion?(true, msg)
            } else {
                // 2. 当前 item 失败或未通过门禁（试听残卷），无感触发跨平台全网自动换源轮询！
                DispatchQueue.main.async {
                    self.activeDownloads[item.id] = .downloading(progressText: "[\(item.source.rawValue)] 音源受限/试听，正在全网跨平台换源...")
                }
                self.searchTracks(query: "\(item.title) \(item.artist)") { [weak self] candidates in
                    guard let self = self else { return }
                    let others = candidates.filter { $0.id != item.id }
                    let ranked = MultiFactorScorer.rankCandidates(candidates: others, targetTitle: item.title, targetArtist: item.artist, targetDuration: item.durationSeconds)
                    
                    if !ranked.isEmpty {
                        self.downloadCandidateQueue(queue: ranked, index: 0, targetTitle: item.title, targetArtist: item.artist, targetDuration: item.durationSeconds, uiTrackId: item.id, completion: completion)
                    } else {
                        // 无其他跨平台候选，尝试 yt-dlp 兜底
                        let destDir = DownloadConfig.shared.downloadDirectoryURL
                        let safeTitle = DownloadConfig.cleanFileName(item.title)
                        let safeArtist = DownloadConfig.cleanFileName(item.artist)
                        let baseFileName = "\(safeTitle) - \(safeArtist)"
                        let lrcDestURL = destDir.appendingPathComponent("\(baseFileName).lrc")
                        
                        self.fallbackWithYtDlp(title: item.title, artist: item.artist, targetDuration: item.durationSeconds, destDir: destDir, lrcDestURL: lrcDestURL, trackId: item.id) { ytSuccess, ytMsg in
                            if !ytSuccess {
                                let failMsg = "全网多平台接口均仅提供试听片段，已阻止保存残卷"
                                DispatchQueue.main.async {
                                    self.activeDownloads[item.id] = .failed(error: failMsg)
                                    completion?(false, failMsg)
                                }
                            } else {
                                completion?(true, ytMsg)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // 通过文件头魔数或 HTTP 响应判定音频扩展名 (.mp3 / .flac / .ogg)
    private func detectAudioExtension(fileURL: URL, response: URLResponse?, fallbackFormat: String?) -> String {
        if let fileHandle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? fileHandle.close() }
            let headerData = fileHandle.readData(ofLength: 4)
            if headerData.count >= 4 {
                if headerData.starts(with: [0x66, 0x4C, 0x61, 0x43]) { // "fLaC"
                    return "flac"
                }
                if headerData.starts(with: [0x4F, 0x67, 0x67, 0x53]) { // "OggS"
                    return "ogg"
                }
            }
        }
        
        if let mime = response?.mimeType?.lowercased() {
            if mime.contains("flac") {
                return "flac"
            } else if mime.contains("ogg") {
                return "ogg"
            } else if mime.contains("mpeg") || mime.contains("mp3") {
                return "mp3"
            }
        }
        
        if let respUrl = response?.url?.pathExtension.lowercased(), !respUrl.isEmpty {
            if respUrl == "flac" { return "flac" }
            if respUrl == "ogg" { return "ogg" }
            if respUrl == "mp3" { return "mp3" }
        }
        
        if let fallback = fallbackFormat?.lowercased() {
            if fallback == "flac" { return "flac" }
            if fallback == "ogg" { return "ogg" }
            if fallback == "mp3" { return "mp3" }
        }
        
        return "mp3"
    }
    
    // 抓取并写入格式化 LRC
    private func fetchAndSaveLrc(candidate: SearchTrackItem, title: String, artist: String, album: String, destURL: URL, completion: @escaping (Bool) -> Void) {
        let writeLrcBlock: (String) -> Void = { lrcContent in
            var header = ""
            if !lrcContent.contains("[ti:") { header += "[ti:\(title)]\n" }
            if !lrcContent.contains("[ar:") { header += "[ar:\(artist)]\n" }
            if !album.isEmpty && !lrcContent.contains("[al:") { header += "[al:\(album)]\n" }
            
            let finalLrc = header + lrcContent
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try finalLrc.write(to: destURL, atomically: true, encoding: .utf8)
                completion(true)
            } catch {
                completion(false)
            }
        }
        
        // 若为网易云音源，优先通过网易官方 API 获取原生 LRC
        if candidate.source == .netease && candidate.numericId > 0,
           let lrcApiUrl = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(candidate.numericId)&lv=-1&kv=-1&tv=-1") {
            var req = URLRequest(url: lrcApiUrl)
            req.timeoutInterval = 4.0
            
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let lrcObj = json["lrc"] as? [String: Any],
                   let text = lrcObj["lyric"] as? String, !text.isEmpty {
                    writeLrcBlock(text)
                    return
                }
                
                // 网易云无歌词时走全网歌词引擎兜底
                self?.fetchGenericLrc(title: title, artist: artist, writeBlock: writeLrcBlock)
            }.resume()
        } else {
            // 其他平台音源直接调用全网同步歌词引擎
            fetchGenericLrc(title: title, artist: artist, writeBlock: writeLrcBlock)
        }
    }
    
    private func fetchGenericLrc(title: String, artist: String, writeBlock: @escaping (String) -> Void) {
        LyricsEngine.shared.fetchLyrics(title: title, artist: artist, durationMs: 0) { lines in
            if let lines = lines, !lines.isEmpty {
                var reconstructed = ""
                for l in lines {
                    let m = Int(l.time) / 60
                    let s = l.time.truncatingRemainder(dividingBy: 60)
                    reconstructed += String(format: "[%02d:%05.2f]%@\n", m, s, l.text)
                }
                writeBlock(reconstructed)
            } else {
                writeBlock("")
            }
        }
    }
    
    // yt-dlp 兜底下载 (带物理时长门禁)
    private func fallbackWithYtDlp(title: String, artist: String, targetDuration: Double, destDir: URL, lrcDestURL: URL, trackId: String, completion: ((Bool, String) -> Void)?) {
        guard let ytdlpPath = findYtDlpPath() else {
            DispatchQueue.main.async {
                self.activeDownloads[trackId] = .failed(error: "全网音源受版权保护且未检测到本地 yt-dlp 兜底工具")
                completion?(false, "音源受版权保护且未检测到本地 yt-dlp")
            }
            return
        }
        
        DispatchQueue.main.async {
            self.activeDownloads[trackId] = .downloading(progressText: "全网公开接口受限，正在通过本地 yt-dlp 兜底...")
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let safeTitle = DownloadConfig.cleanFileName(title)
            let safeArtist = DownloadConfig.cleanFileName(artist)
            let audioDestURL = destDir.appendingPathComponent("\(safeTitle) - \(safeArtist).mp3")
            let ytTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ytdlpPath)
            process.arguments = [
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "0",
                "-o", ytTempURL.path,
                "ytsearch1:\(title) \(artist)"
            ]
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: ytTempURL.path) {
                    let gateResult = AntiPreviewGate.inspectAudio(at: ytTempURL, targetDuration: targetDuration)
                    switch gateResult {
                    case .fail(let reason, _):
                        try? FileManager.default.removeItem(at: ytTempURL)
                        DispatchQueue.main.async {
                            let errMsg = "yt-dlp 兜底音源未通过时长门禁: \(reason)"
                            self.activeDownloads[trackId] = .failed(error: errMsg)
                            completion?(false, errMsg)
                        }
                    case .pass(let actualSec):
                        if FileManager.default.fileExists(atPath: audioDestURL.path) {
                            try? FileManager.default.removeItem(at: audioDestURL)
                        }
                        try FileManager.default.moveItem(at: ytTempURL, to: audioDestURL)
                        
                        let dummyItem = SearchTrackItem(id: "ytdlp", numericId: 0, source: .all, title: title, artist: artist, album: "", durationSeconds: actualSec, qualityTag: "320K", extraData: [:])
                        self.fetchAndSaveLrc(candidate: dummyItem, title: title, artist: artist, album: "", destURL: lrcDestURL) { _ in
                            DispatchQueue.main.async {
                                self.activeDownloads[trackId] = .completed
                                self.notifyDownloadComplete(title: title, artist: artist, audioURL: audioDestURL, lrcURL: lrcDestURL)
                                completion?(true, "yt-dlp 兜底下载完成 (时长: \(String(format: "%.1f", actualSec))s)")
                            }
                        }
                    }
                } else {
                    try? FileManager.default.removeItem(at: ytTempURL)
                    DispatchQueue.main.async {
                        self.activeDownloads[trackId] = .failed(error: "yt-dlp 执行未成功")
                        completion?(false, "yt-dlp 执行未成功")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: ytTempURL)
                DispatchQueue.main.async {
                    self.activeDownloads[trackId] = .failed(error: error.localizedDescription)
                    completion?(false, error.localizedDescription)
                }
            }
        }
    }
    
    private func findYtDlpPath() -> String? {
        var candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yt-dlp").path,
            NSString(string: "~/.local/bin/yt-dlp").expandingTildeInPath,
            "/usr/bin/yt-dlp",
            "/bin/yt-dlp"
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            candidates.append("\(home)/.local/bin/yt-dlp")
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.components(separatedBy: ":") where !dir.isEmpty {
                candidates.append("\(dir)/yt-dlp")
            }
        }
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return c
            }
        }
        return nil
    }
    
    // 下载完成通知与 Finder 高亮定位、曲库刷新
    private func notifyDownloadComplete(title: String, artist: String, audioURL: URL, lrcURL: URL) {
        showSystemBanner(title: "已完成音乐与歌词下载", informativeText: "\(title) - \(artist)\n已保存至: \(DownloadConfig.shared.displayPath)")
        
        var targets: [URL] = []
        if FileManager.default.fileExists(atPath: audioURL.path) { targets.append(audioURL) }
        if FileManager.default.fileExists(atPath: lrcURL.path) { targets.append(lrcURL) }
        if !targets.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
        
        // 自动通知本地音乐曲库重新扫描刷新
        LocalMusicLibrary.shared.scanTracks()
    }
    
    // 一键下载当前 Spotify 正在播放曲目 (四维多源聚合与跨平台自动换源)
    func downloadCurrentPlaying(title: String, artist: String, targetDuration: Double = 0, completion: ((Bool, String) -> Void)? = nil) {
        let cleanT = cleanTrackTitle(title)
        let cleanA = cleanArtistName(artist)
        let query = "\(cleanT) \(cleanA)"
        let uiTrackId = "playing_\(cleanT)_\(cleanA)"
        
        searchTracks(query: query) { [weak self] items in
            guard let self = self else { return }
            
            if items.isEmpty {
                self.searchTracks(query: "\(title) \(artist)") { [weak self] fallbackItems in
                    guard let self = self else { return }
                    self.processAndStartDownload(candidates: fallbackItems, targetTitle: title, targetArtist: artist, targetDuration: targetDuration, uiTrackId: uiTrackId, completion: completion)
                }
            } else {
                self.processAndStartDownload(candidates: items, targetTitle: title, targetArtist: artist, targetDuration: targetDuration, uiTrackId: uiTrackId, completion: completion)
            }
        }
    }
    
    private func processAndStartDownload(candidates: [SearchTrackItem], targetTitle: String, targetArtist: String, targetDuration: Double, uiTrackId: String, completion: ((Bool, String) -> Void)?) {
        let ranked = MultiFactorScorer.rankCandidates(candidates: candidates, targetTitle: targetTitle, targetArtist: targetArtist, targetDuration: targetDuration)
        
        if ranked.isEmpty {
            let destDir = DownloadConfig.shared.downloadDirectoryURL
            let safeTitle = DownloadConfig.cleanFileName(targetTitle)
            let safeArtist = DownloadConfig.cleanFileName(targetArtist)
            let baseFileName = "\(safeTitle) - \(safeArtist)"
            let lrcDestURL = destDir.appendingPathComponent("\(baseFileName).lrc")
            
            self.fallbackWithYtDlp(title: targetTitle, artist: targetArtist, targetDuration: targetDuration, destDir: destDir, lrcDestURL: lrcDestURL, trackId: uiTrackId) { success, msg in
                if !success {
                    let failMsg = "全网未检索到匹配的完整正曲音源（候选歌手不符或均为试听）"
                    DispatchQueue.main.async {
                        self.activeDownloads[uiTrackId] = .failed(error: failMsg)
                        completion?(false, failMsg)
                    }
                } else {
                    completion?(true, msg)
                }
            }
            return
        }
        
        let effUiId = !uiTrackId.isEmpty ? uiTrackId : (ranked.first?.id ?? "unknown")
        self.downloadCandidateQueue(queue: ranked, index: 0, targetTitle: targetTitle, targetArtist: targetArtist, targetDuration: targetDuration, uiTrackId: effUiId, completion: completion)
    }
}

// MARK: - 13. 独立原生音乐搜索与下载窗口 (SearchDownloadView & SearchWindowManager)
class SearchViewModel: ObservableObject {
    @Published var keyword: String = ""
    @Published var isSearching: Bool = false
    @Published var results: [SearchTrackItem] = []
    @Published var selectedPlatform: MusicSourcePlatform = .all
    @Published var hasSearched: Bool = false
    @Published var errorMessage: String? = nil
    
    var filteredResults: [SearchTrackItem] {
        if selectedPlatform == .all {
            return results
        }
        return results.filter { $0.source == selectedPlatform }
    }
    
    func search() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isSearching = true
        errorMessage = nil
        hasSearched = true
        
        SongDownloadEngine.shared.searchTracks(query: trimmed) { [weak self] items in
            self?.isSearching = false
            self?.results = items
            if items.isEmpty {
                self?.errorMessage = "全网未检索到匹配的曲目，请更换关键词重试"
            }
        }
    }
}

struct SearchDownloadView: View {
    @StateObject private var vm = SearchViewModel()
    @ObservedObject private var engine = SongDownloadEngine.shared
    @ObservedObject private var config = DownloadConfig.shared
    
    var body: some View {
        ZStack {
            // 毛玻璃背板
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, state: .active)
            
            VStack(spacing: 0) {
                // 顶部标题、搜索栏与平台过滤胶囊
                headerSearchBar
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                
                Divider().background(Color.white.opacity(0.12))
                
                // 中部列表或提示区
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider().background(Color.white.opacity(0.12))
                
                // 底部目录信息栏
                footerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 600, height: 530)
        .onExitCommand {
            SearchWindowManager.shared.closeWindow()
        }
    }
    
    // 顶部搜索栏与平台过滤
    private var headerSearchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "music.note.magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                Text("全网多源聚合搜索与分布式下载")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text("ESC 键关闭")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.40))
            }
            
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.50))
                    
                    TextField("输入歌名、歌手或专辑，按回车全网搜索...", text: $vm.keyword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white)
                        .onSubmit {
                            vm.search()
                        }
                    
                    if !vm.keyword.isEmpty {
                        Button(action: { vm.keyword = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.50))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
                
                Button(action: { vm.search() }) {
                    HStack(spacing: 4) {
                        if vm.isSearching {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 13))
                        }
                        Text("全网搜索")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.blue.opacity(0.80))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSearching || vm.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            
            // 平台分类切换胶囊
            platformFilterBar
        }
    }
    
    // 平台切换胶囊栏
    private var platformFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(MusicSourcePlatform.allCases) { platform in
                let isSelected = vm.selectedPlatform == platform
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.selectedPlatform = platform
                    }
                }) {
                    HStack(spacing: 5) {
                        if platform != .all {
                            Circle()
                                .fill(platform.badgeColor)
                                .frame(width: 6, height: 6)
                        }
                        Text(platform.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.06))
                    )
                    .foregroundColor(isSelected ? .white : .white.opacity(0.70))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? platform.badgeColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
    
    // 内容展示区
    @ViewBuilder
    private var contentArea: some View {
        if vm.isSearching {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .scaleEffect(1.1)
                Text("正在全网四大平台并发检索高品质音轨与 LRC 歌词...")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                Spacer()
            }
        } else if vm.filteredResults.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: vm.hasSearched ? "music.slash" : "sparkles")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.30))
                
                Text(vm.errorMessage ?? (vm.hasSearched ? (vm.selectedPlatform == .all ? "未找到相关音乐" : "当前平台 [\(vm.selectedPlatform.rawValue)] 未找到结果，可切换至【全部】或其他平台") : "搜索并一键下载最高音质音频与同步歌词"))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                
                Text("支持网易云、酷狗、酷我、QQ音乐四维多源聚合与跨平台无感自动换源")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.white.opacity(0.40))
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.filteredResults) { item in
                        trackRowView(item: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
    
    // 曲目行项视图
    private func trackRowView(item: SearchTrackItem) -> some View {
        let status = engine.activeDownloads[item.id] ?? .idle
        
        return HStack(spacing: 8) {
            // 来源平台 Badge
            platformBadge(source: item.source)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(item.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                    
                    if !item.album.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                        Text(item.album)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.50))
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // 时长
            Text(item.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 44, alignment: .trailing)
            
            // 音质标签
            qualityBadge(tag: item.qualityTag)
            
            // 下载操作区
            downloadButton(item: item, status: status)
                .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
    
    // 平台彩色 Badge
    private func platformBadge(source: MusicSourcePlatform) -> some View {
        Text(source.badgeShortTitle)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(source.badgeColor.opacity(0.90))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    
    // 音质 Badge
    private func qualityBadge(tag: String) -> some View {
        let isFlac = tag.uppercased() == "FLAC"
        let is320 = tag.uppercased() == "320K"
        
        let bgColor: Color = isFlac ? Color(red: 0.95, green: 0.60, blue: 0.15) : (is320 ? Color(red: 0.20, green: 0.78, blue: 0.40) : Color.gray.opacity(0.50))
        let textColor: Color = .white
        
        return Text(tag)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bgColor.opacity(0.85))
            .clipShape(Capsule())
    }
    
    // 下载按钮与状态交互
    @ViewBuilder
    private func downloadButton(item: SearchTrackItem, status: TrackDownloadStatus) -> some View {
        switch status {
        case .idle:
            Button(action: {
                engine.downloadTrack(item: item)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                    Text("下载")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.90))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            
        case .downloading(let msg):
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("下载中")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(Color.yellow.opacity(0.90))
            }
            .help(msg)
            
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color.green)
                Text("已完成")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.green)
            }
            
        case .failed(let err):
            Button(action: {
                engine.downloadTrack(item: item)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("重试")
                        .font(.system(size: 11, design: .rounded))
                }
                .foregroundColor(Color.red.opacity(0.90))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.15))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("错误: \(err)")
        }
    }
    
    // 底部状态条
    private var footerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.60))
            
            Text("保存目录:")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white.opacity(0.60))
            
            Button(action: {
                config.openInFinder()
            }) {
                Text(config.displayPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                    .underline()
            }
            .buttonStyle(.plain)
            .help("点击在 Finder 中打开下载目录")
            
            Spacer()
            
            Button(action: {
                config.selectDirectory(window: SearchWindowManager.shared.currentWindow)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 11))
                    Text("更改目录...")
                        .font(.system(size: 12, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }
}


// 支持 ESC 键关闭的定制原生窗口
class SearchWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC 键
            self.orderOut(nil)
            return
        }
        super.keyDown(with: event)
    }
}

// 搜索窗口管理器
class SearchWindowManager: NSObject, NSWindowDelegate {
    static let shared = SearchWindowManager()
    
    private(set) var currentWindow: NSWindow?
    
    func showWindow() {
        if let win = currentWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = SearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "音乐搜索与下载"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.center()
        win.delegate = self
        
        let hostingView = NSHostingView(rootView: SearchDownloadView())
        win.contentView = hostingView
        
        self.currentWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow() {
        currentWindow?.orderOut(nil)
    }
    
    func windowWillClose(_ notification: Notification) {
        self.currentWindow = nil
    }
}

// MARK: - 13. 本地音乐曲库界面与独立毛玻璃窗口管理器 (LocalMusicView & LocalMusicWindowManager)

// 支持 ESC 键关闭的定制本地曲库原生毛玻璃窗口 (尺寸 600x520)
class LocalMusicWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC 键
            self.orderOut(nil)
            return
        }
        super.keyDown(with: event)
    }
}

class LocalMusicWindowManager: NSObject, NSWindowDelegate {
    static let shared = LocalMusicWindowManager()
    
    private(set) var currentWindow: NSWindow?
    
    func showWindow() {
        if let win = currentWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = LocalMusicWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "本地音乐曲库"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.minSize = NSSize(width: 500, height: 420)
        win.center()
        win.delegate = self
        
        let hostingView = NSHostingView(rootView: LocalMusicView())
        win.contentView = hostingView
        
        self.currentWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow() {
        currentWindow?.orderOut(nil)
    }
    
    func toggleWindow() {
        if let win = currentWindow, win.isVisible {
            win.orderOut(nil)
        } else {
            showWindow()
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        self.currentWindow = nil
    }
}

struct LocalMusicView: View {
    @ObservedObject private var library = LocalMusicLibrary.shared
    @ObservedObject private var player = LocalMusicPlayer.shared
    @State private var searchText: String = ""
    @State private var selectedTrackId: UUID?

    var filteredTracks: [LocalTrackItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            return library.tracks
        }
        return library.tracks.filter {
            $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            // 独立原生毛玻璃背板
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, state: .active)

            VStack(spacing: 0) {
                // 1. 顶部标题与路径控制区
                headerView
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                // 2. 搜索过滤栏
                searchBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)

                Divider().background(Color.white.opacity(0.12))

                // 3. 曲目列表内容区
                trackListView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().background(Color.white.opacity(0.12))

                // 4. 底部 Mini 播放控制栏
                bottomPlayerBar
            }
        }
        .frame(width: 600, height: 520)
        .onExitCommand {
            LocalMusicWindowManager.shared.closeWindow()
        }
    }

    // 顶部标题与路径
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                Text("本地音乐曲库")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Text("共 \(library.tracks.count) 首曲目")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))

                Text("ESC 退出")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.yellow.opacity(0.85))
                    Text(library.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.80))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))

                Spacer()

                Button(action: {
                    library.selectDirectory { _ in }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.gear")
                        Text("更换目录")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button(action: {
                    library.openInFinder()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Finder")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button(action: {
                    library.scanTracks()
                }) {
                    Image(systemName: library.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("重新扫描曲库")
            }
        }
    }

    // 搜索过滤栏
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.50))

            TextField("搜索曲目名或歌手...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.50))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.30))
        )
    }

    // 曲目列表
    private var trackListView: some View {
        Group {
            if library.isScanning && library.tracks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在扫描本地曲库...")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.60))
                }
            } else if filteredTracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.25))
                    Text(library.tracks.isEmpty ? "当前目录下暂无音频文件 (.mp3, .flac, .m4a, .wav)" : "未找到匹配曲目")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.50))
                    if library.tracks.isEmpty {
                        Button("从 Finder 导入或更换目录") {
                            library.selectDirectory { _ in }
                        }
                        .font(.system(size: 12))
                        .padding(.top, 4)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, item in
                            trackRowView(index: index, item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // 单行曲目项
    private func trackRowView(index: Int, item: LocalTrackItem) -> some View {
        let isCurrent = player.currentTrack?.url == item.url
        let isSelected = selectedTrackId == item.id

        return HStack(spacing: 10) {
            // 播放指示器或序号
            Group {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.3.fill" : "speaker.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(width: 22, alignment: .center)

            // 歌曲与歌手
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: isCurrent ? .bold : .medium, design: .rounded))
                    .foregroundColor(isCurrent ? Color(red: 0.35, green: 0.95, blue: 0.90) : .white)
                    .lineLimit(1)

                Text(item.artist)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.50))
                    .lineLimit(1)
            }

            Spacer()

            // LRC 标签
            if item.hasLrc {
                Text("LRC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.20, green: 0.85, blue: 0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.20, green: 0.85, blue: 0.55).opacity(0.18))
                    )
            } else {
                Text("无歌词")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }

            // 时长
            Text(item.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.40))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.12) : (isSelected ? Color.white.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            player.playTrack(item, in: filteredTracks)
        }
        .onTapGesture(count: 1) {
            selectedTrackId = item.id
        }
    }

    // 底部 Mini 播放栏
    private var bottomPlayerBar: some View {
        VStack(spacing: 6) {
            // 进度条与时间
            HStack(spacing: 8) {
                Text(formatSeconds(player.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.50))
                    .frame(width: 36, alignment: .leading)

                Slider(
                    value: Binding<Double>(
                        get: { player.currentTime },
                        set: { newTime in
                            player.seek(to: newTime)
                        }
                    ),
                    in: 0...max(1.0, player.duration)
                )
                .accentColor(Color(red: 0.35, green: 0.95, blue: 0.90))

                Text(formatSeconds(player.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.50))
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                // 左侧正在播放信息
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))

                    if let cur = player.currentTrack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cur.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(cur.artist)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.white.opacity(0.50))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                    } else {
                        Text("未在播放本地曲目")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.40))
                    }
                }

                Spacer()

                // 中间控制按钮
                HStack(spacing: 16) {
                    Button(action: { player.previous() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button(action: { player.togglePlayPause() }) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                    }
                    .buttonStyle(.plain)

                    Button(action: { player.next() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // 右侧循环模式切换
                Button(action: {
                    player.isSingleLoop.toggle()
                }) {
                    Image(systemName: player.isSingleLoop ? "repeat.1" : "repeat")
                        .font(.system(size: 12))
                        .foregroundColor(player.isSingleLoop ? Color(red: 0.35, green: 0.95, blue: 0.90) : .white.opacity(0.50))
                }
                .buttonStyle(.plain)
                .help(player.isSingleLoop ? "当前：单曲循环" : "当前：列表循环")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.25))
    }

    private func formatSeconds(_ sec: Double) -> String {
        guard sec > 0, !sec.isNaN, !sec.isInfinite else { return "00:00" }
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 10. 主应用控制器与状态栏菜单
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hostingView: NSHostingView<LyricFloatingView>?
    let vm = LyricViewModel()
    var timer: Timer?

    private var isMiniMode: Bool = false
    private var lastExpandedHeight: CGFloat = 160.0

    private var isAlwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "isAlwaysOnTop") }
        set {
            UserDefaults.standard.set(newValue, forKey: "isAlwaysOnTop")
            window.level = newValue ? .floating : .normal
            vm.isAlwaysOnTop = newValue
            updateMenu()
        }
    }

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
            styleMask: [.titled, .resizable, .miniaturizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = isAlwaysOnTop ? .floating : .normal
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        window.minSize = NSSize(width: 260, height: 50)
        window.maxSize = NSSize(width: 8000, height: 5000)

        if UserDefaults.standard.string(forKey: "WindowFrame") == nil, let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.origin.x + (screenFrame.width - 560) / 2
            let y = screenFrame.origin.y + 60
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.ignoresMouseEvents = isClickThrough

        vm.onToggleAlwaysOnTop = { [weak self] in
            self?.toggleAlwaysOnTop()
        }
        vm.onMinimizeWindow = { [weak self] in
            self?.minimizeWindow()
        }
        vm.onCloseWindow = { [weak self] in
            self?.closeWindow()
        }
        vm.onQuitApp = { [weak self] in
            self?.quitApp()
        }

        let doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClickGesture.numberOfClicksRequired = 2

        let hv = NSHostingView(rootView: LyricFloatingView(vm: vm))
        hv.addGestureRecognizer(doubleClickGesture)
        self.hostingView = hv

        window.contentView = hv
        window.makeKeyAndOrderFront(nil)

        // 注册局部/全局快捷键监听：⌘F 打开搜索窗口，⌘S 下载当前曲目，⌘L 打开本地曲库，⌘O 选择音乐目录
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "f" {
                    self?.openSearchWindow()
                    return nil
                } else if key == "s" {
                    self?.downloadCurrentTrackAction()
                    return nil
                } else if key == "l" {
                    self?.openLocalMusicWindow()
                    return nil
                } else if key == "o" {
                    self?.chooseLocalMusicFolder()
                    return nil
                }
            }
            return event
        }

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

    func windowDidMiniaturize(_ notification: Notification) {
        updateMenu()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateMenu()
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

    func updateMenu() {
        statusItem.menu = buildAppMenu()
        hostingView?.menu = buildAppMenu()
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu()
        let count = RobustLyricsCache.shared.getCachedCount()
        let titleItem = NSMenuItem(title: "🎵 Spotify 歌词助手 V6.0", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // 🎵 本地音乐曲库入口 (⌘L)
        menu.addItem(NSMenuItem(title: "🎵 本地音乐曲库... (⌘L)", action: #selector(openLocalMusicWindow), keyEquivalent: "l"))

        // 🔍 音乐搜索与双轨下载入口 (⌘F)
        menu.addItem(NSMenuItem(title: "🔍 搜索并下载音乐... (⌘F)", action: #selector(openSearchWindow), keyEquivalent: "f"))
        
        // ⬇️ 下载当前播放曲目 (⌘S)
        let curTitle = vm.currentTrackTitle
        let curArtist = vm.currentTrackArtist
        let downloadTitle = curTitle.isEmpty ? "⬇️ 下载当前播放曲目 (⌘S)" : "⬇️ 下载当前歌曲: \(curTitle) - \(curArtist) (⌘S)"
        menu.addItem(NSMenuItem(title: downloadTitle, action: #selector(downloadCurrentTrackAction), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())

        let isShown = window != nil && window.isVisible && !window.isMiniaturized
        if isShown {
            menu.addItem(NSMenuItem(title: "关闭歌词窗口 (隐藏到后台)", action: #selector(closeWindow), keyEquivalent: "w"))
        } else {
            menu.addItem(NSMenuItem(title: "打开 / 恢复歌词窗口", action: #selector(toggleWindow), keyEquivalent: "w"))
        }

        menu.addItem(NSMenuItem(title: "显示 / 隐藏 桌面歌词", action: #selector(toggleWindow), keyEquivalent: "h"))

        let topTitle = isAlwaysOnTop ? "✓ 窗口永远置顶 (已开启)" : "开启窗口永远置顶模式"
        menu.addItem(NSMenuItem(title: topTitle, action: #selector(toggleAlwaysOnTop), keyEquivalent: "t"))

        let miniTitle = (window != nil && window.isMiniaturized) ? "从 Dock 恢复歌词窗口" : "最小化歌词窗口到 Dock"
        menu.addItem(NSMenuItem(title: miniTitle, action: #selector(minimizeWindow), keyEquivalent: "m"))

        let clickThroughTitle = isClickThrough ? "✓ 鼠标点击穿透模式 (已开启)" : "开启鼠标点击穿透模式"
        let clickThroughItem = NSMenuItem(title: clickThroughTitle, action: #selector(toggleClickThrough), keyEquivalent: "p")
        menu.addItem(clickThroughItem)

        menu.addItem(NSMenuItem(title: "双击折叠/展开单行模式", action: #selector(handleDoubleClick), keyEquivalent: "d"))
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
        // 📁 本地音乐与下载目录管理
        let localDirTitle = "📁 本地曲库目录: \(LocalMusicLibrary.shared.displayPath)"
        menu.addItem(NSMenuItem(title: localDirTitle, action: #selector(openLocalMusicFolderInFinder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "📂 选择本地音乐目录... (⌘O)", action: #selector(chooseLocalMusicFolder), keyEquivalent: "o"))

        let dirTitle = "📁 音乐下载目录: \(DownloadConfig.shared.displayPath)"
        menu.addItem(NSMenuItem(title: dirTitle, action: #selector(openDownloadFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⚙️ 更改音乐下载目录...", action: #selector(changeDownloadFolder), keyEquivalent: ""))

        if vm.playbackSource == .local {
            menu.addItem(NSMenuItem(title: "📻 切换回 Spotify 模式", action: #selector(switchToSpotifyAction), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "🔄 强制重新拉取当前歌词", action: #selector(reloadLyrics), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "🗑 清除本地歌词缓存 (已缓存 \(count) 首)", action: #selector(clearLyricsCache), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重置窗口大小与居中", action: #selector(resetWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 SpotifyLyrics", action: #selector(quitApp), keyEquivalent: "q"))

        return menu
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

    @objc func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
    }

    @objc func minimizeWindow() {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        } else {
            window.miniaturize(nil)
        }
        updateMenu()
    }

    @objc func closeWindow() {
        window.orderOut(nil)
        updateMenu()
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
        if window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        updateMenu()
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

    @objc func openSearchWindow() {
        SearchWindowManager.shared.showWindow()
    }

    @objc func openLocalMusicWindow() {
        LocalMusicWindowManager.shared.toggleWindow()
    }

    @objc func chooseLocalMusicFolder() {
        LocalMusicLibrary.shared.selectDirectory(window: window) { [weak self] _ in
            self?.updateMenu()
        }
    }

    @objc func openLocalMusicFolderInFinder() {
        LocalMusicLibrary.shared.openInFinder()
    }

    @objc func switchToSpotifyAction() {
        vm.switchToSpotify()
        updateMenu()
    }

    @objc func downloadCurrentTrackAction() {
        let title = vm.currentTrackTitle
        let artist = vm.currentTrackArtist
        let duration = vm.currentTrackDurationSeconds
        guard !title.isEmpty else {
            showSystemBanner(title: "未检测到播放曲目", informativeText: "请先在 Spotify 中播放歌曲，或使用 ⌘F 搜索下载。")
            return
        }
        
        showSystemBanner(title: "开始下载当前曲目", informativeText: "正在检索 \(title) - \(artist) 的最高音质音轨与歌词...")
        
        SongDownloadEngine.shared.downloadCurrentPlaying(title: title, artist: artist, targetDuration: duration) { success, msg in
            if !success {
                showSystemBanner(title: "下载未成功", informativeText: "\(title) - \(artist)\n提示: \(msg)")
            }
        }
    }

    @objc func openDownloadFolder() {
        DownloadConfig.shared.openInFinder()
    }

    @objc func changeDownloadFolder() {
        DownloadConfig.shared.selectDirectory(window: window) { [weak self] _ in
            self?.updateMenu()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            updateMenu()
        }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
