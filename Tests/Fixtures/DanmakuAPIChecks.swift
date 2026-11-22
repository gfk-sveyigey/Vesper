import Foundation
let source = DanmakuAPISource(name: "test", address: "https://example.com/prefix/token/")
let url = try source.endpoint(["search", "anime"], query: [.init(name: "keyword", value: "三体 & test")])
assert(url.path == "/prefix/token/api/v2/search/anime")
assert(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value == "三体 & test")
let full = DanmakuAPISource(name: "test", address: "https://example.com/prefix/api/v2")
let fullURL = try full.endpoint(["bangumi", "42"]); assert(fullURL.path == "/prefix/api/v2/bangumi/42")
let json = #"{"success":true,"comments":[{"p":"2,1,16777215,user","m":"滚动"},{"p":"1,5,255,user","m":"顶部"},{"p":"nan,1,0,user","m":"bad"},{"p":"3,7,0,user","m":"unsupported"}]}"#
let comments = try DanmakuAPI.parseComments(Data(json.utf8))
assert(comments.count == 2 && comments[0].text == "顶部" && comments[1].color == 16777215)
for address in ["http://example.com", "https://example.com?token=a", "https://user:pass@example.com", "not-url"] {
 do { _ = try DanmakuAPISource(name: "", address: address).endpoint([]); fatalError("bad address") } catch {}
}
print("API URL and JSON tests passed")

let trailing = try DanmakuAPISource(name: "", address: "https://example.com/prefix/api/v2/").endpoint(["comment", "42"])
assert(trailing.path == "/prefix/api/v2/comment/42")
for json in [#"{"success":false}"#, #"{"comments":[]}"#, #"{"comments":[{"p":"1,7,0,user","m":"bad"}]}"#] {
    do { _ = try DanmakuAPI.parseComments(Data(json.utf8)); fatalError("Should reject invalid comments") } catch {}
}
let stringIDs = DanmakuAPI.items([["animeId":"abc", "animeTitle":"title"], ["animeId":"../bad"]], id: "animeId", title: "animeTitle")
assert(stringIDs.count == 1 && stringIDs[0].id == "abc")

// Layout settings must affect the actual renderer's production layout.
func comment(_ time: Double, _ mode: Int = 1, _ text: String = "hello") -> DanmakuComment {
    .init(time: time, mode: mode, color: 0xFFFFFF, text: text)
}
func layout(_ comments: [DanmakuComment], _ options: DanmakuDisplayOptions) -> [DanmakuPlacement] {
    DanmakuLayout.build(comments: comments, width: 400, height: 800, options: options, measure: { Double($0.count * 20) })
}
var options = DanmakuDisplayOptions()
options.filterDuplicates = false
let barrage = (0..<30).map { comment(0, 1, "item \($0)") }
options.density = 1
let low = layout(barrage, options)
options.density = 3
let high = layout(barrage, options)
assert(high.count > low.count)
assert(Set(high.map(\.y)).count == high.count)
assert(high.allSatisfy { $0.y + 15 <= 700 })
options.area = 0.25
let quarter = layout(barrage, options)
options.area = 1
let fullLayout = layout(barrage, options)
assert(fullLayout.count > quarter.count)
assert(fullLayout.allSatisfy { $0.y + 15 <= 700 })
options.avoidSubtitles = false
assert(layout(barrage, options).count >= fullLayout.count)
options.speed = 2
assert(layout([comment(0)], options)[0].lifetime == 4)
options.speed = 0.5
assert(layout([comment(0)], options)[0].lifetime == 16)
options.scrolling = false
assert(layout([comment(0)], options).isEmpty)
options.top = false; options.bottom = false
assert(layout([comment(0, 4), comment(0, 5)], options).isEmpty)
options.scrolling = true
options.blockedWords = "BAD，剧透; spoiler\n广告"
assert(layout([comment(0, 1, "contains bad word"), comment(1, 1, "有剧透"), comment(2, 1, "clean")], options).map(\.comment.text) == ["clean"])
options.blockedWords = ""
options.filterDuplicates = true
assert(layout([comment(0), comment(1), comment(11)], options).count == 2)
options.filterDuplicates = false
assert(layout([comment(0), comment(1), comment(11)], options).count == 3)
assert(DanmakuLayout.build(comments: barrage, width: 0, height: 0, options: options, measure: { _ in 10 }).isEmpty)
print("Danmaku display settings and layout tests passed")

assert(DanmakuSearchQuery.make(title: " 剧集 ", season: 1, seasonCount: 1) == "剧集")
assert(DanmakuSearchQuery.make(title: "剧集", season: 1, seasonCount: 3) == "剧集 第1季")
assert(DanmakuSearchQuery.make(title: "剧集", season: 2, seasonCount: nil) == "剧集 第2季")
assert(DanmakuSearchQuery.make(title: "电影", season: nil, seasonCount: nil) == "电影")
