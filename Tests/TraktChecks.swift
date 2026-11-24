// Foundation-only checks. test_trakt.py supplies production policies and a fake transport/store.
@main
struct TraktChecks {
    @MainActor static func main() async throws {
        let profile = try JSONDecoder().decode(TraktAccountSettings.self, from: Data(#"{"user":{"username":"viewer","name":"  ","vip":false,"vip_ep":true,"images":{"avatar":{"full":"https://example.com/avatar.jpg"}}}}"#.utf8)).user
        precondition(profile.displayName == "viewer")
        precondition(profile.isVIP && profile.avatarURL?.scheme == "https")
        let minimal = try JSONDecoder().decode(TraktAccountUser.self, from: Data(#"{"username":"viewer"}"#.utf8))
        precondition(!minimal.isVIP && minimal.avatarURL == nil)
        let statistics = try JSONDecoder().decode(TraktAccountStatistics.self, from: Data(#"{"movies":{"watched":12,"plays":15,"minutes":1200},"shows":{"watched":3},"episodes":{"watched":25,"plays":30,"minutes":1000}}"#.utf8))
        precondition(statistics.movies.watched == 12) // Unique titles, not repeat plays.
        precondition(statistics.shows.watched == 3 && statistics.episodes.watched == 25)
        precondition(statistics.watchedMinutes == 2200) // Movie + episode time only.

        var state = TraktScrobbleState()
        precondition(state.update(playing: false, ended: false) == nil)
        precondition(state.finish() == nil) // Open failure/loading never creates a record.
        precondition(state.update(playing: true, ended: false) == .start)
        precondition(state.update(playing: true, ended: false) == nil)
        precondition(state.update(playing: false, ended: false) == .pause)
        precondition(state.update(playing: false, ended: false) == nil)
        precondition(state.update(playing: true, ended: false) == .start)
        precondition(state.update(playing: false, ended: true) == .stop)
        precondition(state.update(playing: false, ended: true) == nil)
        precondition(state.finish() == nil)

        precondition(TraktScrobbleState.progress(position: 50, duration: 100) == 50)
        precondition(TraktScrobbleState.progress(position: 110, duration: 100) == 100)
        precondition(TraktScrobbleState.progress(position: -1, duration: 100) == 0)
        precondition(TraktScrobbleState.progress(position: .nan, duration: 100) == nil)
        precondition(TraktScrobbleState.progress(position: 0, duration: 0) == nil)
        let ids = TraktMediaIdentity.supportedIDs([
            "IMDb": "tt12345", "Tmdb": "42", "TVDB": "8", "Trakt": "17",
            "Douban": "123", "Bad": "../token"
        ])
        precondition(ids == ["imdb": "tt12345", "tmdb": "42", "tvdb": "8", "trakt": "17"])
        precondition(TraktMediaIdentity.supportedIDs(["Imdb": "tt12/path", "Tmdb": "-1", "Trakt": "0"]).isEmpty)
        let media = TraktMediaIdentity(kind: "movie", ids: ids)
        precondition(media.jsonIDs["tmdb"] as? Int == 42)
        precondition(media.jsonIDs["imdb"] as? String == "tt12345")

        let token = TraktToken(access_token: "a", refresh_token: "r", created_at: 100, expires_in: 600)
        precondition(token.isValid)
        precondition(!token.needsRefresh(at: Date(timeIntervalSince1970: 639)))
        precondition(token.needsRefresh(at: Date(timeIntervalSince1970: 640)))
        precondition(!TraktToken(access_token: "", refresh_token: "r", created_at: 100, expires_in: 600).isValid)

        precondition(EmbyProgressPriority.order("") == [.trakt, .server, .local])
        precondition(EmbyProgressPriority.order("local,trakt,server") == [.local, .trakt, .server])
        precondition(EmbyProgressPriority.order("local,local,unknown") == [.local, .trakt, .server])
        precondition(EmbyProgressPriority.validPosition(nil, duration: 100) == nil)
        precondition(EmbyProgressPriority.validPosition(.nan, duration: 100) == nil)
        precondition(EmbyProgressPriority.validPosition(-1, duration: 100) == nil)
        precondition(EmbyProgressPriority.validPosition(0, duration: 100) == 0)
        precondition(EmbyProgressPriority.validPosition(40, duration: 100) == 40)
        precondition(EmbyProgressPriority.validPosition(99, duration: 100) == 0)
        precondition(TraktResumeProgress.seconds(percent: 25, duration: 400) == 100)
        precondition(TraktResumeProgress.seconds(percent: 100, duration: 400) == 0)
        precondition(TraktResumeProgress.seconds(percent: 101, duration: 400) == nil)
        precondition(TraktResumeProgress.seconds(percent: nil, duration: 400) == nil)
        precondition(TraktResumeProgress.seconds(percent: 50, duration: 0) == nil)
        precondition(TraktResumeProgress.matches(["trakt": "42"], responseIDs: ["trakt": 42]))
        precondition(TraktResumeProgress.matches(["imdb": "tt123"], responseIDs: ["imdb": "tt123"]))
        precondition(!TraktResumeProgress.matches(["trakt": "42"], responseIDs: ["trakt": 43]))
        precondition(!TraktResumeProgress.matches(["imdb": "tt123"], responseIDs: [:]))
        let playbackIdentity = TraktMediaIdentity(kind: "movie", ids: ["tmdb": "42"])
        let playbackRows: [[String: Any]] = [
            ["id": 10, "progress": 35, "movie": ["ids": ["tmdb": 42]]],
            ["id": 11, "progress": 50, "movie": ["ids": ["tmdb": 43]]],
            ["id": 12, "progress": 60, "episode": ["ids": ["tmdb": 42]]]
        ]
        precondition(TraktResumeProgress.playbackIDsToRemove(playbackRows, identity: playbackIdentity) == [10])
        let episodeIdentity = TraktMediaIdentity(kind: "episode", ids: ["trakt": "99"], season: 2, episode: 4)
        let episodeRows: [[String: Any]] = [
            ["id": 20, "show": ["ids": ["trakt": 42]], "episode": ["season": 2, "number": 4]],
            ["id": 21, "show": ["ids": ["trakt": 42]], "episode": ["season": 2, "number": 3]],
            ["id": 22, "show": ["ids": ["trakt": 99]], "episode": ["season": 2, "number": 4]]
        ]
        precondition(TraktResumeProgress.playbackIDsToRemove(episodeRows, identity: episodeIdentity) == [22])

        let showIdentity = TraktMediaIdentity(kind: "show", ids: ["trakt": "42"])
        let watchedEpisodes = TraktResumeProgress.watchedEpisodes([
            "seasons": [["number": 2, "episodes": [
                ["number": 1, "completed": true], ["number": 2, "completed": false]
            ]]]
        ])
        precondition(watchedEpisodes[TraktEpisodeKey(season: 2, episode: 1)]?.isPlayed == true)
        precondition(watchedEpisodes[TraktEpisodeKey(season: 2, episode: 2)]?.isPlayed == false)
        let pausedEpisodes = TraktResumeProgress.pausedEpisodes([
            ["show": ["ids": ["trakt": 42]], "episode": ["season": 2, "number": 2], "progress": 37.5],
            ["show": ["ids": ["trakt": 99]], "episode": ["season": 2, "number": 2], "progress": 88]
        ], showIdentity: showIdentity)
        precondition(pausedEpisodes[TraktEpisodeKey(season: 2, episode: 2)] == 37.5)
        precondition(pausedEpisodes.count == 1)

        let shared = Harness()
        let revision = shared.accountRevision
        let requests = (0..<20).map { _ in
            Task { @MainActor in
                let access = try await shared.accessToken(revision: revision)
                precondition(shared.saved) // Persist both tokens before any caller can use the result.
                return access
            }
        }
        for request in requests {
            let value = try await request.value
            precondition(value == "new")
        }
        precondition(shared.calls == 1)
        precondition(shared.token?.refresh_token == "rotated")
        let recovered = try await shared.accessToken(revision: revision, rejectedToken: "old")
        precondition(recovered == "new" && shared.calls == 1) // Concurrent 401 from obsolete token.
        precondition(shared.refreshing == nil)

        let http = Harness()
        http.token = TraktToken(access_token: "old", refresh_token: "refresh",
                                created_at: Date().timeIntervalSince1970, expires_in: 600)
        http.network.statuses = [401, 201]
        let body = Data(#"{"progress":75}"#.utf8)
        _ = try await http.api("scrobble/pause", method: "POST", body: body, revision: http.accountRevision)
        precondition(http.calls == 1)
        precondition(http.network.requests.count == 2)
        let sent = http.network.requests
        precondition(sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer old")
        precondition(sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer new")
        precondition(sent[1].value(forHTTPHeaderField: "trakt-api-key") == "test-client")
        precondition(sent[1].value(forHTTPHeaderField: "trakt-api-version") == "2")
        precondition(sent[1].httpBody == body && sent[1].httpMethod == "POST")
        precondition(sent[1].url?.absoluteString == "https://api.trakt.tv/scrobble/pause")

        http.network.statuses = [429]
        do {
            _ = try await http.api("scrobble/start", method: "POST", body: body, revision: http.accountRevision)
            preconditionFailure()
        } catch { precondition(http.retryDelay(for: error) == 7) }
        let count = http.network.requests.count
        http.network.statuses = [500]
        do {
            _ = try await http.api("scrobble/stop", method: "POST", body: body, revision: http.accountRevision)
            preconditionFailure()
        } catch {}
        precondition(http.network.requests.count == count + 1) // Ambiguous writes are not replayed.

        let rejected = Harness()
        rejected.network.statuses = [401, 401]
        do {
            _ = try await rejected.api("scrobble/start", method: "POST", body: body, revision: rejected.accountRevision)
            preconditionFailure()
        } catch {}
        precondition(rejected.disconnected && rejected.network.requests.count == 2)

        let logout = Harness()
        let oldRevision = logout.accountRevision
        let pending = Task { @MainActor in try await logout.accessToken(revision: oldRevision) }
        try await Task.sleep(for: .milliseconds(1))
        logout.disconnect()
        do { _ = try await pending.value; preconditionFailure("Stale refresh returned a token") }
        catch {}
        precondition(!logout.saved && logout.token == nil)

        let diskFailure = Harness()
        diskFailure.storageFails = true
        do { _ = try await diskFailure.accessToken(revision: diskFailure.accountRevision); preconditionFailure() }
        catch {}
        precondition(diskFailure.disconnected && !diskFailure.saved)

        let revoked = Harness()
        revoked.responseStatus = 400
        do { _ = try await revoked.accessToken(revision: revoked.accountRevision); preconditionFailure() }
        catch {}
        precondition(revoked.disconnected)

        let offline = Harness()
        offline.networkFails = true
        do { _ = try await offline.accessToken(revision: offline.accountRevision); preconditionFailure() }
        catch {}
        precondition(!offline.disconnected && offline.token?.refresh_token == "refresh")
        precondition(offline.refreshing == nil)
    }
}
