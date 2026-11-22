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

        let searchArtist = (track.artist == "未知歌手") ? "" : track.artist
        LyricsEngine.shared.fetchLyrics(title: track.title, artist: searchArtist, durationMs: durationMs) { [weak self] list in
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
                } else if !searchArtist.isEmpty && track.title != searchArtist {
                    // 智能降级尝试：部分文件名可能是 "歌手 - 歌名" 反转，尝试对调再搜一次
                    LyricsEngine.shared.fetchLyrics(title: searchArtist, artist: track.title, durationMs: durationMs) { [weak self] fallbackList in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            guard self.requestToken == currentToken else { return }
                            if let fallbackList = fallbackList, !fallbackList.isEmpty {
                                self.lyrics = fallbackList
                                self.isShowingLyrics = true
                                self.updateLyricsPosition(pos: LocalMusicPlayer.shared.currentTime)
                                var reconstructed = ""
                                if !track.title.isEmpty { reconstructed += "[ti:\(track.title)]\n" }
                                if !track.artist.isEmpty { reconstructed += "[ar:\(track.artist)]\n" }
                                for l in fallbackList {
                                    let m = Int(l.time) / 60
                                    let s = l.time.truncatingRemainder(dividingBy: 60)
                                    reconstructed += String(format: "[%02d:%05.2f]%@\n", m, s, l.text)
                                }
                                try? reconstructed.write(to: lrcURL, atomically: true, encoding: .utf8)
                                LocalMusicLibrary.shared.markTrackHasLrc(trackId: track.id, lrcURL: lrcURL)
                            } else {
                                self.placeholderTitle = "🎵 \(track.title)"
                                self.placeholderSubtitle = "\(track.artist) (全网检索完毕，暂无匹配歌词)"
                            }
                        }
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
    var title: String
    var artist: String
    var duration: Double // 单位：秒 (支持自适应探测与播放校准)
    var hasLrc: Bool
    var lrcURL: URL?

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var formattedDuration: String {
        guard duration > 0, !duration.isNaN, !duration.isInfinite else { return "--:--" }
        let total = Int(duration)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - FFmpeg 深度音频探测与全格式转码播放支持引擎
class FFmpegAudioHelper {
    static let shared = FFmpegAudioHelper()

    private let ffmpegCandidatePaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    private let ffprobeCandidatePaths = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe"
    ]

    var ffmpegPath: String? {
        for path in ffmpegCandidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    var ffprobePath: String? {
        for path in ffprobeCandidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SpotifyLyrics/AudioCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // 探测音频时长与标签 (当 AVURLAsset 无法解析特殊格式如 ogg/opus/ape/wma 时使用)
    func probeMetadata(url: URL) -> (duration: Double, title: String?, artist: String?) {
        guard let probe = ffprobePath else { return (0, nil, nil) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: probe)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration:format_tags=title,artist:stream_tags=title,artist",
            "-of", "default=noprint_wrappers=1",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return (0, nil, nil)
            }

            var dur: Double = 0
            var title: String? = nil
            var artist: String? = nil

            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("duration=") {
                    let valStr = String(trimmed.dropFirst("duration=".count))
                    if let d = Double(valStr), !d.isNaN, !d.isInfinite, d > 0 {
                        dur = d
                    }
                } else if trimmed.lowercased().hasPrefix("tag:title=") {
                    let valStr = String(trimmed.dropFirst("tag:title=".count)).trimmingCharacters(in: .whitespaces)
                    if !valStr.isEmpty && title == nil {
                        title = valStr
                    }
                } else if trimmed.lowercased().hasPrefix("tag:artist=") {
                    let valStr = String(trimmed.dropFirst("tag:artist=".count)).trimmingCharacters(in: .whitespaces)
                    if !valStr.isEmpty && artist == nil {
                        artist = valStr
                    }
                }
            }

            return (dur, title, artist)
        } catch {
            return (0, nil, nil)
        }
    }

    // 将非原生或解析失败的音频无损转码为标准 16-bit PCM WAV 缓存文件后供 AVAudioPlayer 播放
    func transcodeToWav(sourceURL: URL) throws -> URL {
        guard let ffmpeg = ffmpegPath else {
            throw NSError(
                domain: "FFmpegAudioHelper",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 ffmpeg，播放此类格式需安装 ffmpeg (如 brew install ffmpeg)"]
            )
        }

        let attr = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attr?[.size] as? NSNumber)?.int64Value ?? 0
        let modTime = (attr?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKeyData = "\(sourceURL.path)_\(fileSize)_\(modTime)".data(using: .utf8) ?? Data()
        let cacheKey = SHA256.hash(data: cacheKeyData).compactMap { String(format: "%02x", $0) }.joined()

        let targetURL = cacheDirectory.appendingPathComponent("\(cacheKey).wav")

        // 检查缓存有效性 (若已存在且大于 1KB，直接秒开复用)
        if FileManager.default.fileExists(atPath: targetURL.path),
           let targetAttr = try? FileManager.default.attributesOfItem(atPath: targetURL.path),
           let targetSize = (targetAttr[.size] as? NSNumber)?.int64Value, targetSize > 1024 {
            return targetURL
        }

        // 调用 ffmpeg 进行快速 PCM WAV 转码
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-vn",
            "-acodec", "pcm_s16le",
            "-ar", "44100",
            "-ac", "2",
            targetURL.path
        ]

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 && FileManager.default.fileExists(atPath: targetURL.path) else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
            throw NSError(
                domain: "FFmpegAudioHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "FFmpeg 转码失败: \(errMsg)"]
            )
        }

        return targetURL
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
    @Published var isTranscoding: Bool = false
    @Published var volume: Float = 1.0 {
        didSet {
            audioPlayer?.volume = volume
        }
    }

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var playRequestId: UUID = UUID()

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

        let thisRequestId = UUID()
        self.playRequestId = thisRequestId

        audioPlayer?.stop()
        self.currentTime = 0.0
        self.currentTrack = track
        self.isPlaying = false

        let ext = track.fileExtension
        let nativeCoreAudioExts: Set<String> = [
            "mp3", "flac", "m4a", "wav", "aac", "alac", "aiff", "aif", "aifc", "caf", "m4b", "m4r"
        ]

        // 步骤 1：若属于 CoreAudio 原生格式，直接尝试 AVAudioPlayer 硬件解码播放
        if nativeCoreAudioExts.contains(ext) {
            do {
                let player = try AVAudioPlayer(contentsOf: track.url)
                self.setupAndStartPlayer(player, track: track, reqId: thisRequestId)
                return
            } catch {
                print("CoreAudio 原生解码 \(track.url.lastPathComponent) 抛错，自动切换 FFmpeg PCM 转码回退: \(error)")
            }
        }

        // 步骤 2：对于特殊格式 (ogg, oga, opus, ape, wma 等) 或原生直接播放抛错时：
        // 自动使用本地 ffmpeg 转码为标准 PCM WAV 缓存文件后送入 AVAudioPlayer 播放
        self.isTranscoding = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let transcodedWavURL = try FFmpegAudioHelper.shared.transcodeToWav(sourceURL: track.url)
                let player = try AVAudioPlayer(contentsOf: transcodedWavURL)
                DispatchQueue.main.async {
                    guard self.playRequestId == thisRequestId else { return }
                    self.isTranscoding = false
                    self.setupAndStartPlayer(player, track: track, reqId: thisRequestId)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.playRequestId == thisRequestId else { return }
                    self.isTranscoding = false
                    print("FFmpeg 转码或播放失败: \(error)")
                    showSystemBanner(
                        title: "播放本地音频失败",
                        informativeText: "无法播放 \(track.title): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func setupAndStartPlayer(_ player: AVAudioPlayer, track: LocalTrackItem, reqId: UUID) {
        guard self.playRequestId == reqId else { return }
        self.audioPlayer = player
        player.delegate = self
        player.volume = self.volume
        player.prepareToPlay()
        player.play()

        self.isPlaying = true
        let realDuration = player.duration > 0 ? player.duration : track.duration
        self.duration = realDuration

        // 时长安全校准：若曲目原时长为空或存在误差，同步校准曲库元数据，避免 00:00
        if track.duration <= 0 || abs(track.duration - realDuration) > 1.0 {
            LocalMusicLibrary.shared.updateTrackDuration(trackId: track.id, duration: realDuration)
        }

        startProgressTimer()

        var updatedTrack = track
        updatedTrack.duration = realDuration
        LyricViewModel.shared?.playLocalTrack(updatedTrack)
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
            let supportedExts = Set(["mp3", "flac", "m4a", "wav", "aac", "alac", "aiff", "aif", "aifc", "caf", "ogg", "oga", "opus", "ape", "wma", "m4b", "m4r"])

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
                var finalDur = (dur.isNaN || dur.isInfinite || dur < 0) ? 0.0 : dur

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

                // 若 AVURLAsset 无法获取时长或元数据（常见于 ogg, opus, ape, wma 等特殊格式），使用 FFmpeg/ffprobe 深入探测
                if finalDur <= 0 || title == baseName || artist == "未知歌手" {
                    let probed = FFmpegAudioHelper.shared.probeMetadata(url: fileURL)
                    if finalDur <= 0 && probed.duration > 0 {
                        finalDur = probed.duration
                    }
                    if title == baseName, let pTitle = probed.title, !pTitle.isEmpty {
                        title = pTitle
                    }
                    if artist == "未知歌手", let pArtist = probed.artist, !pArtist.isEmpty {
                        artist = pArtist
                    }
                }

                // 兜底时长保护：若最终依然无法获取时长，根据文件大小做安全保底估算，避免显示 00:00
                if finalDur <= 0 {
                    let attr = try? fm.attributesOfItem(atPath: fileURL.path)
                    let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
                    if size > 0 {
                        let estimatedSec = Double(size) / (192.0 * 1024.0 / 8.0)
                        if estimatedSec > 5.0 && estimatedSec < 7200.0 {
                            finalDur = estimatedSec
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
            if let idx = LocalMusicPlayer.shared.playlist.firstIndex(where: { $0.id == trackId }) {
                LocalMusicPlayer.shared.playlist[idx].hasLrc = true
                LocalMusicPlayer.shared.playlist[idx].lrcURL = lrcURL
            }
        }
    }

    func updateTrackDuration(trackId: UUID, duration: Double) {
        guard duration > 0, !duration.isNaN, !duration.isInfinite else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.tracks.firstIndex(where: { $0.id == trackId }) {
                self.tracks[idx].duration = duration
            }
            if let idx = LocalMusicPlayer.shared.playlist.firstIndex(where: { $0.id == trackId }) {
                LocalMusicPlayer.shared.playlist[idx].duration = duration
            }
            if LocalMusicPlayer.shared.currentTrack?.id == trackId {
                LocalMusicPlayer.shared.currentTrack?.duration = duration
            }
        }
    }
}

// MARK: - 11. 统一系统原生横幅通知与开源免责声明 (System Banner & Legal Disclaimer)

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

// 开源免责与法律合规声明 (Legal Disclaimer & Safe Harbor)
func showLegalDisclaimerAlert(window: NSWindow? = nil) {
    let alert = NSAlert()
    alert.messageText = "⚖️ 关于 SpotifyLyrics 与法律合规声明"
    alert.informativeText = """
    【开源中立性与法律避风港免责声明】

    1. 中立媒体工具定位：
       SpotifyLyrics 是一款基于开源协议开发的个人桌面歌词同步与本地媒体播放管理工具。软件定位为纯中立中转框架，遵循法律“避风港原则”（Safe Harbor）。

    2. 无版权内容存储与分发：
       本项目与开发者绝不提供、不存储、不分发任何受商业版权保护的音频文件，源码中绝不内置任何第三方未授权音源、逆向破解或歌曲下载接口。

    3. 本地播放与公开歌词联动：
       应用仅支持用户本地已有合法音频的播放及公网开放歌词接口的联动展示。歌词版权均归其各自原权利人所有。

    4. 合规自担责任：
       使用者对其本地播放的媒体文件合法性自担相应法律责任，与本项目及开发者无关。
    """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "我已知晓并同意")
    if let win = window {
        alert.beginSheetModal(for: win, completionHandler: nil)
    } else {
        alert.runModal()
    }
}

// MARK: - 12. 本地音乐曲库界面与独立毛玻璃窗口管理器 (LocalMusicView & LocalMusicWindowManager)

// 支持 ESC 键与 ⌘W 独立关闭的定制本地曲库原生毛玻璃窗口 (尺寸 600x520)
class LocalMusicWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isReleasedWhenClosed = false
    }

    override func performClose(_ sender: Any?) {
        self.orderOut(nil)
        (NSApp.delegate as? AppDelegate)?.updateMenu()
    }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
        (NSApp.delegate as? AppDelegate)?.updateMenu()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC 键
            self.orderOut(nil)
            (NSApp.delegate as? AppDelegate)?.updateMenu()
            return
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "w" {
            self.orderOut(nil)
            (NSApp.delegate as? AppDelegate)?.updateMenu()
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
            (NSApp.delegate as? AppDelegate)?.updateMenu()
            return
        }
        
        let win = LocalMusicWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
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
        (NSApp.delegate as? AppDelegate)?.updateMenu()
    }
    
    func closeWindow() {
        currentWindow?.orderOut(nil)
        (NSApp.delegate as? AppDelegate)?.updateMenu()
    }
    
    func toggleWindow() {
        if let win = currentWindow, win.isVisible {
            win.orderOut(nil)
            (NSApp.delegate as? AppDelegate)?.updateMenu()
        } else {
            showWindow()
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.updateMenu()
    }
}

// MARK: - 高保真音频格式标签组件 (FormatBadgeView)
struct FormatBadgeView: View {
    let ext: String

    var badgeText: String {
        ext.uppercased()
    }

    var badgeColor: Color {
        switch ext.lowercased() {
        case "flac":
            return Color(red: 1.0, green: 0.55, blue: 0.15) // FLAC: 橙色
        case "alac", "wav", "aiff", "aif", "aifc", "caf":
            return Color(red: 0.25, green: 0.65, blue: 1.0) // ALAC / WAV / AIFF: 蓝色
        case "ape", "ogg", "oga", "opus":
            return Color(red: 0.75, green: 0.45, blue: 1.0) // OGG / OPUS / APE: 紫色
        case "wma":
            return Color(red: 0.35, green: 0.75, blue: 0.85) // WMA: 青蓝
        case "mp3", "aac", "m4a", "m4b", "m4r":
            fallthrough
        default:
            return Color(red: 0.25, green: 0.85, blue: 0.55) // MP3 / AAC: 绿色
        }
    }

    var body: some View {
        Text(badgeText)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundColor(badgeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(badgeColor.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(badgeColor.opacity(0.35), lineWidth: 0.5)
            )
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
            HStack(spacing: 8) {
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

                // 关闭按钮
                Button(action: {
                    LocalMusicWindowManager.shared.closeWindow()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                        Text("关闭面板 (后台持续播放音乐与歌词)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("关闭曲库窗口 (ESC / ⌘W)，音乐与桌面歌词将在后台持续播放")
            }

            // 格式支持提示栏
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                Text("全格式自适应: MP3 · FLAC · WAV · AAC · ALAC · AIFF · OGG · OPUS · APE · WMA · CAF")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )

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
                    Text(library.tracks.isEmpty ? "当前目录下暂无音频文件 (支持 MP3, FLAC, WAV, AAC, ALAC, AIFF, OGG, OPUS, APE, WMA 等全格式)" : "未找到匹配曲目")
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
                    if player.isTranscoding {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: player.isPlaying ? "speaker.wave.3.fill" : "speaker.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.90))
                    }
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

            // 格式 Badge（FLAC 橙色、ALAC/WAV/AIFF 蓝色、MP3/AAC 绿色、OGG/APE 紫色）
            FormatBadgeView(ext: item.fileExtension)

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
                Text("云歌词")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.40))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
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

                Text(formatSeconds(player.duration, isDuration: true))
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
                            Text(cur.artist + (player.isTranscoding ? " · 解码中..." : ""))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(player.isTranscoding ? Color(red: 0.35, green: 0.95, blue: 0.90) : .white.opacity(0.50))
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

    private func formatSeconds(_ sec: Double, isDuration: Bool = false) -> String {
        if isDuration && (sec <= 0 || sec.isNaN || sec.isInfinite) {
            return "--:--"
        }
        guard sec > 0, !sec.isNaN, !sec.isInfinite else { return "00:00" }
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 13. 主应用控制器与状态栏菜单
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
        window.isReleasedWhenClosed = false

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

        // 注册局部/全局快捷键监听：⌘L 打开本地曲库，⌘O 选择音乐目录，⌘W 窗口隔离精准关闭
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "l" {
                    self.openLocalMusicWindow()
                    return nil
                } else if key == "o" {
                    self.chooseLocalMusicFolder()
                    return nil
                } else if key == "w" {
                    // 统一 ⌘W 处理逻辑：严格按当前活动窗口独立关闭，绝不连锁关闭！
                    if let localWin = LocalMusicWindowManager.shared.currentWindow, localWin.isKeyWindow {
                        LocalMusicWindowManager.shared.closeWindow()
                        return nil
                    } else if self.window.isKeyWindow {
                        self.closeWindow()
                        return nil
                    }
                    return nil // 消费掉 ⌘W，避免无焦或在其他视图下误触发
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

        // 1. 桌面歌词窗口独立状态控制项 (移除全局 w 快捷键冲突)
        let isLyricVisible = (window != nil && window.isVisible && !window.isMiniaturized)
        let lyricTitle = isLyricVisible ? "✓ 桌面歌词窗口: 显示中 (点击隐藏)" : "桌面歌词窗口: 已隐藏 (点击恢复显示)"
        menu.addItem(NSMenuItem(title: lyricTitle, action: #selector(toggleWindow), keyEquivalent: "h"))

        // 2. 本地音乐曲库独立状态控制项 (⌘L)
        let isLocalWinVisible = LocalMusicWindowManager.shared.currentWindow?.isVisible == true
        let localTitle = isLocalWinVisible ? "✓ 本地音乐曲库: 已打开 (点击收起)" : "🎵 本地音乐曲库... (⌘L)"
        menu.addItem(NSMenuItem(title: localTitle, action: #selector(openLocalMusicWindow), keyEquivalent: "l"))

        menu.addItem(NSMenuItem.separator())

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
        // 📁 本地音乐曲库目录管理
        let localDirTitle = "📁 本地曲库目录: \(LocalMusicLibrary.shared.displayPath)"
        menu.addItem(NSMenuItem(title: localDirTitle, action: #selector(openLocalMusicFolderInFinder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "📂 选择本地音乐目录... (⌘O)", action: #selector(chooseLocalMusicFolder), keyEquivalent: "o"))


        if vm.playbackSource == .local {
            menu.addItem(NSMenuItem(title: "📻 切换回 Spotify 模式", action: #selector(switchToSpotifyAction), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "⚖️ 关于与法律合规声明...", action: #selector(showLegalDisclaimerAction), keyEquivalent: ""))
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

    @objc func showLegalDisclaimerAction() {
        showLegalDisclaimerAlert(window: window)
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
