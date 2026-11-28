from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SourceContextManagementTests(unittest.TestCase):
    def test_source_removal_clears_local_records_without_final_online_reports(self):
        sources = (ROOT / "Vesper/Features/Sources/SourcesView.swift").read_text()
        playback = (ROOT / "Vesper/Infrastructure/Playback/PlaybackSession.swift").read_text()
        emby = (ROOT / "Vesper/Infrastructure/Playback/EmbyPlaybackSession.swift").read_text()
        trakt = (ROOT / "Vesper/Infrastructure/Services/TraktAccountStore.swift").read_text()
        self.assertIn("playback.removeLocalPlaybackData(sourceID: id)", sources)
        removal = playback.split("func removeLocalPlaybackData(", 1)[1].split("/// Called after", 1)[0]
        self.assertIn("stop(savePlaybackRecord: false)", removal)
        self.assertIn("removePlaybackData { $0.sourceID == sourceID }", removal)
        self.assertIn("traktReporter.finish(reportStop: savePlaybackRecord)", playback)
        self.assertIn("tearDownPlayer(reportStop: savePlaybackRecord)", playback)
        self.assertIn("retiringEmbySession?.finish(reportStop: reportStop)", playback)
        self.assertIn('if started, reportStop { enqueue(action: "stopped") }', emby)
        self.assertIn("if reportStop, let action = state.finish(),", trakt)

    def test_emby_save_treats_route_discovery_as_optional_after_verification(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        save = source.split("func saveEmby(", 1)[1].split("func updateEmbyIcon(", 1)[0]
        verification, discovery_and_save = save.split("if validated.fetchAlternateAddresses == true", 1)
        discovery, commit = discovery_and_save.split("let index = id.flatMap", 1)
        self.assertIn("try await accounts.prepareAuthentication(", verification)
        self.assertIn("try await accounts.verifyConnection(for: candidate)", verification)
        self.assertNotIn("catch", verification)
        self.assertIn("validated.mergeServerRoutes(routes)", discovery.split("} catch", 1)[0])
        self.assertIn("catch is CancellationError", discovery)
        self.assertIn("try Task.checkCancellation()", discovery.split("} catch {", 1)[1])
        self.assertIn("persist()", commit)
        refresh = source.split("func refreshEmbyRoutes(", 1)[1].split("func remove(", 1)[0]
        self.assertIn("try await EmbyRepository.shared.alternateRoutes(for: source)", refresh)

    def test_icon_and_route_actions_use_independent_sheets(self):
        sources = (ROOT / "Vesper/Features/Sources/SourcesView.swift").read_text()
        self.assertIn('sourceManagement = .icon(source)', sources)
        self.assertIn('sourceManagement = .routes(source)', sources)
        self.assertIn("SourceIconEditSheet(source: source)", sources)
        self.assertIn("SourceRouteManagementSheet(source: source)", sources)
        self.assertNotIn("entry: .icon", sources)
        self.assertNotIn("entry: .routes", sources)

    def test_active_route_is_retained_and_retested_after_address_change(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        update = source.split("func updateEmbyRoutes", 1)[1].split("func switchEmbyRoute", 1)[0]
        self.assertIn("guard let activeRoute", update)
        self.assertIn("configuration.serverAddress = activeRoute.address", update)
        self.assertIn("verifyEmbyConnection(id)", update)

    def test_route_switch_menus_share_icon_and_reserve_unselected_checkmark_space(self):
        sources = (ROOT / "Vesper/Features/Sources/SourcesView.swift").read_text()
        media = (ROOT / "Vesper/Features/Media/MediaView.swift").read_text()
        self.assertIn('Menu("切换线路", systemImage: "arrow.left.arrow.right")', sources)
        self.assertIn('Text("切换线路") } icon: { menuSymbol("arrow.left.arrow.right")', media)
        self.assertIn('menuSymbol("checkmark", visible: isSelected)\n                    .frame(width: 20, height: 20)', media)
        source_menu = sources.split('Menu("切换线路"', 1)[1].split("Button(\"移除来源\"", 1)[0]
        self.assertIn('routeMenuIcon(isSelected: key == EmbyRouteOptions.key(configuration.serverAddress))', source_menu)
        route_icon = sources.split('private func routeMenuIcon(', 1)[1].split('private func removeSource(', 1)[0]
        self.assertIn('if isSelected { return Image(systemName: "checkmark") }', route_icon)
        self.assertIn('Image(uiImage: Self.emptyRouteMenuIcon).renderingMode(.original)', route_icon)

    def test_emby_home_failure_does_not_restore_disk_cache(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        loader = source.split("private func loadEmbyMediaGroups", 1)[1].split("private func prepareCarousel", 1)[0]
        failure = loader.rsplit("} catch {", 1)[1]
        self.assertIn("embyHome = nil", failure)
        self.assertIn("content = .failed", failure)
        self.assertNotIn("cache.items", failure)
        self.assertIn('cache.save(libraries, scope: scope, key: "libraries:media-only"', loader)
        self.assertIn('key: "latest:titles:', loader)
        self.assertIn('key: "featured:titles"', loader)

    def test_emby_cache_is_preview_only_and_refresh_failure_is_reported(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        loader = source.split("private func loadEmbyMediaGroups", 1)[1].split("private func prepareCarousel", 1)[0]
        media = (ROOT / "Vesper/Features/Media/MediaView.swift").read_text()
        self.assertIn('cache.items(scope: scope, key: "libraries:media-only")', loader)
        self.assertIn('key: "latest:titles:', loader)
        self.assertIn('if group.isLoading && group.items.isEmpty', media)
        self.assertIn('if groupLoadFailed { throw EmbyError.invalidResponse }', loader)


if __name__ == "__main__":
    unittest.main()
