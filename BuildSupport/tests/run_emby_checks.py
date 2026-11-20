"""Compile the real Swift Emby client and exercise it against a local HTTP server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import os
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]

EVENTS = []
MEDIA = {'Id': 'v2', 'Name': 'Version 2', 'RunTimeTicks': 6000000000, 'Container': 'mkv',
         'Path': '/library/Movie/movie-v2.mkv', 'Size': 7340032000, 'Bitrate': 48000000,
         'SupportsDirectPlay': True, 'SupportsDirectStream': True, 'SupportsTranscoding': True,
         'MediaStreams': [{'Type': 'Subtitle', 'IsExternal': True, 'Index': 2, 'Codec': 'srt',
                           'DisplayTitle': '中文', 'Language': 'chi', 'IsHearingImpaired': True,
                           'IsForced': False, 'DeliveryMethod': 'External', 'Path': '/subs/movie.zh.srt'},
                          {'Type': 'Audio', 'Index': 1, 'Codec': 'eac3', 'Profile': 'Atmos',
                           'Language': 'eng', 'DisplayTitle': 'English - EAC3 - 5.1', 'Channels': 6,
                           'ChannelLayout': '5.1', 'SampleRate': 48000, 'BitDepth': 24, 'BitRate': 768000,
                           'IsDefault': True}]}
ITEM = {'Id': 'movie', 'Name': 'Movie', 'Type': 'Movie', 'RunTimeTicks': 6000000000,
        'UserData': {'PlaybackPositionTicks': 300000000}, 'Overview': 'A movie',
        'PrimaryImageAspectRatio': 1.78,
        'SeriesId': 'series', 'SeriesPrimaryImageTag': 'series-tag',
        'MediaSources': [dict(MEDIA, Id='v1', Name='Version 1'), MEDIA]}
SERIES = {'Id': 'series', 'Name': 'Series', 'Type': 'Series', 'IsFolder': True,
          'DateCreated': '2026-11-18T01:58:30Z', 'PremiereDate': '2024-03-01',
          'Genres': ['Drama', 'Mystery'], 'Status': 'Continuing', 'OfficialRating': 'TV-14',
          'AirDays': ['Monday'], 'AirTime': '20:00', 'OriginalTitle': 'Original Series',
          'Studios': [{'Name': 'Example Network'}], 'Tags': ['investigation'],
          'ProductionLocations': ['Japan'], 'SeasonCount': 2, 'CommunityRating': 8.4,
          'ImageTags': {'Primary': 'cover', 'Logo': 'logo'}}
EPISODE = {'Id': 'episode', 'Name': 'Episode', 'Type': 'Episode', 'SeriesId': 'series'}

EPISODE_USER_DATA = {'PlaybackPositionTicks': 300000000, 'Played': False, 'IsFavorite': True}
EXPECTED_EPISODE_WRITES = [
    {'PlaybackPositionTicks': 300000000, 'Played': True, 'IsFavorite': True},
    {'PlaybackPositionTicks': 300000000, 'Played': False, 'IsFavorite': True},
    {'PlaybackPositionTicks': 0, 'Played': False, 'IsFavorite': True},
]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == '/proxy/emby/':
            self.respond({'Id': 'test-server'}); return
        if path.path.startswith('/proxy/emby/Status/'):
            self.send_response(int(path.path.rsplit('/', 1)[1])); self.end_headers(); return
        if path.path.endswith('/Images'):
            item_id = path.path.split('/')[-2]
            images = {
                'movie': [{'ImageType': 'Thumb', 'ImageIndex': 0, 'Width': 1600, 'Height': 900},
                          {'ImageType': 'Primary', 'ImageIndex': 0, 'Width': 600, 'Height': 900}],
                'series': [{'ImageType': 'Logo', 'ImageIndex': 0, 'Width': 800, 'Height': 200},
                           {'ImageType': 'Primary', 'ImageIndex': 0, 'Width': 600, 'Height': 900}],
                'no-logo': [{'ImageType': 'Primary', 'ImageIndex': 0, 'Width': 600, 'Height': 900}],
                'episode': [{'ImageType': 'Thumb', 'ImageIndex': 0, 'Width': 1600, 'Height': 900}],
                'next-season': []
            }
            self.respond(images.get(item_id, [])); return
        if path.path == '/proxy/emby/Items/movie/Images/Primary/0':
            assert self.headers.get('User-Agent') == 'CustomVesper/2.0'
            assert self.headers.get('Accept') == 'image/*,*/*;q=0.8'
            assert self.headers.get('Authorization', '').startswith('Emby UserId="user"')
            assert self.headers.get('X-Emby-Token') == 'secret'
            self.respond({'image': 'movie-primary'}); return
        if path.path == '/proxy/emby/Items/movie/Images/Thumb/0':
            self.respond({'image': 'movie-thumb'}); return
        if path.path == '/proxy/emby/Items/episode/Images/Thumb/0':
            self.respond({'image': 'episode-thumb'}); return
        if path.path == '/proxy/emby/Items/episode/Images/Primary/0':
            self.respond({'image': 'episode-primary'}); return
        if path.path in ('/proxy/emby/Items/next-season/Images/Thumb/0',
                         '/proxy/emby/Items/next-season/Images/Primary/0'):
            self.send_response(404); self.end_headers(); return
        if path.path == '/proxy/emby/Items/series/Images/Primary/0':
            self.respond({'image': 'series'}); return
        if path.path == '/proxy/emby/Items/series/Images/Logo/0':
            assert self.headers.get('X-Emby-Token') == 'secret'
            self.respond({'image': 'logo'}); return
        if path.path == '/proxy/emby/Items/series/RemoteImages':
            query = parse_qs(path.query)
            assert query['Type'] == ['Primary'] and query['IncludeAllLanguages'] == ['true']
            self.respond({'Images': [
                {'Url': 'https://images.example/titled.jpg', 'Width': 600, 'Height': 900, 'Language': 'en'},
                {'Url': 'https://images.example/wide.jpg', 'Width': 900, 'Height': 600, 'Language': None},
                {'Url': 'https://images.example/textless.jpg', 'Width': 600, 'Height': 900, 'Language': None}
            ]}); return
        if path.path == '/proxy/emby/Array':
            self.respond([{'Id': '1'}]); return
        if path.path == '/proxy/emby/Users/user/Views':
            self.respond({'Items': [
                {'Id': 'library', 'Name': 'Movies', 'Type': 'CollectionFolder', 'IsFolder': True},
                {'Id': 'sets', 'Name': 'Sets', 'Type': 'CollectionFolder', 'CollectionType': 'boxsets', 'IsFolder': True},
                {'Id': 'lists', 'Name': 'Lists', 'Type': 'CollectionFolder', 'CollectionType': 'playlists', 'IsFolder': True}
            ]}); return
        if path.path == '/proxy/emby/Users/user/Items':
            query = parse_qs(path.query)
            if 'PersonIds' in query or 'Person' in query:
                assert 'ParentId' not in query and 'Filters' not in query
                assert query['Recursive'] == ['true'] and query['Limit'] == ['21']
                assert query['SortBy'] == ['DateCreated'] and query['SortOrder'] == ['Descending']
                assert set(query['IncludeItemTypes'][0].split(',')) == {'Movie', 'Series', 'Video', 'MusicVideo', 'Trailer'}
                if 'PersonIds' in query:
                    assert query['PersonIds'] == ['actor'] and 'Person' not in query
                    assert query['StartIndex'] == ['21']
                    self.respond({'Items': [ITEM, SERIES]}); return
                assert query['Person'] == ['Director & Writer'] and query['StartIndex'] == ['0']
                self.respond({'Items': [SERIES]}); return
            if query.get('Filters') == ['IsFavorite']:
                assert 'ParentId' not in query and query['Recursive'] == ['true']
                assert query['StartIndex'] == ['21'] and query['Limit'] == ['21']
                assert 'Episode' in query['IncludeItemTypes'][0].split(',')
                self.respond({'Items': [ITEM, SERIES, EPISODE]}); return
            if query['Limit'] in (['10'], ['20']) or query.get('ParentId') == ['library'] and query['Limit'] == ['21']:
                assert set(query['IncludeItemTypes'][0].split(',')) == {'Movie', 'Series', 'Video', 'MusicVideo', 'Trailer'}
            if query['Limit'] == ['10']:
                assert 'ParentId' not in query
                assert query['StartIndex'] == ['0'] and query['Recursive'] == ['true']
                assert query['SortBy'] == ['DateCreated'] and query['SortOrder'] == ['Descending']
                self.respond({'Items': [dict(ITEM, Id=f'featured-{i}') for i in range(9)] + [SERIES]}); return
            if query['Limit'] == ['20']:
                assert query['ParentId'] == ['library']
                assert query['StartIndex'] == ['0'] and query['Recursive'] == ['true']
                assert query['SortBy'] == ['DateCreated'] and query['SortOrder'] == ['Descending']
                self.respond({'Items': [dict(ITEM, Id=f'movie-{i}', DateCreated=f'2026-11-18T01:{59-i:02d}:00.0000000Z') for i in range(19)] + [SERIES]}); return
            if query['Limit'] == ['21']:
                assert query['Recursive'] == ['true']
                if query['ParentId'] == ['library']:
                    assert query['StartIndex'] == ['21']
                    self.respond({'Items': [ITEM, SERIES]}); return
                assert query['ParentId'] == ['series'] and query['StartIndex'] == ['0']
                assert query['IncludeItemTypes'] == ['Episode']
                self.respond({'Items': [EPISODE]}); return
            assert query['StartIndex'] == ['100']
            self.respond({'Items': [ITEM, {'Id': 'book', 'Name': 'Book', 'Type': 'Book'}]}); return
        if path.path == '/proxy/emby/Users/user/Items/movie':
            self.respond(ITEM); return
        if path.path == '/proxy/emby/Users/user/Items/series':
            fields = parse_qs(path.query).get('Fields', [''])[0]
            assert 'AirDays' in fields and 'Studios' in fields and 'SeasonCount' in fields
            self.respond(dict(SERIES, Overview='Series synopsis',
                              People=[{'Id': 'actor', 'Name': 'Actor', 'Role': 'Detective', 'PrimaryImageTag': 'actor-tag'},
                                      {'Name': 'Director & Writer', 'Type': 'Director'}],
                              ProviderIds={'IMDb': 'tt12345', 'Douban': '54321'})); return
        if path.path == '/proxy/emby/Shows/series/Episodes':
            query = parse_qs(path.query)
            assert query['UserId'] == ['user'] and query['EnableUserData'] == ['true']
            next_season = dict(EPISODE, Id='next-season', ParentIndexNumber=2, IndexNumber=1,
                               UserData={'Played': True})
            next_season.pop('Name')
            first_season = dict(EPISODE, ParentIndexNumber=1, IndexNumber=2, Overview='Episode synopsis',
                                ImageTags={'Thumb': 'episode-thumb'}, UserData={'Played': False, 'PlaybackPositionTicks': 300000000},
                                MediaStreams=[{'Type': 'Video', 'Width': 3840, 'VideoRangeType': 'DOVI'},
                                              {'Type': 'Audio', 'DisplayTitle': 'Dolby Atmos'}])
            if query['StartIndex'] == ['0']:
                self.respond({'Items': [next_season], 'TotalRecordCount': 2}); return
            assert query['StartIndex'] == ['1']
            self.respond({'Items': [first_season], 'TotalRecordCount': 2}); return
        if path.path == '/proxy/emby/Items/series/Similar':
            self.respond({'Items': [SERIES, ITEM, EPISODE, ITEM]}); return
        if path.path == '/proxy/emby/Users/user/Items/episode':
            self.respond(dict(EPISODE, UserData=EPISODE_USER_DATA)); return
        if path.path == '/proxy/emby/Events':
            self.respond({'Items': EVENTS}); return
        assert path.path == '/proxy/emby/Echo', path.path
        self.respond({'ua': self.headers.get('User-Agent'), 'token': self.headers.get('X-Emby-Token'),
                      'extra': self.headers.get('X-Test'), 'identity': self.headers.get('Authorization'),
                      'term': parse_qs(path.query).get('term', [''])[0]})

    def do_POST(self):
        if self.path == '/proxy/emby/Empty':
            self.send_response(204); self.end_headers(); return
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/proxy/emby/Users/user/Items/episode/UserData':
            assert EXPECTED_EPISODE_WRITES and payload == EXPECTED_EPISODE_WRITES.pop(0)
            EPISODE_USER_DATA.update(payload)
            self.send_response(204); self.end_headers(); return
        if self.path == '/proxy/emby/Items/movie/PlaybackInfo':
            assert payload['UserId'] == 'user'
            media = dict(MEDIA)
            if not payload['EnableDirectPlay']:
                media['TranscodingUrl'] = '/emby/Videos/movie/master.m3u8?StartTimeTicks=' + str(payload['StartTimeTicks'])
            else:
                assert payload['MediaSourceId'] == 'v2'
                media['DirectStreamUrl'] = '/emby/Videos/movie/stream?static=true&MediaSourceId=v2'
            self.respond({'PlaySessionId': 'server-session', 'MediaSources': [media]}); return
        if self.path == '/proxy/emby/Users/AuthenticateByName':
            assert payload == {'Username': 'alice', 'Pw': 'pw'}
            self.respond({'AccessToken': 'issued-token'}); return
        if '/Sessions/Playing' in self.path:
            EVENTS.append({'path': self.path.removeprefix('/proxy/emby/'), 'body': payload})
            self.send_response(204); self.end_headers(); return
        self.respond(payload)

    def do_DELETE(self):
        if urlsplit(self.path).path == '/proxy/emby/Videos/ActiveEncodings':
            EVENTS.append({'method': 'DELETE', 'query': parse_qs(urlsplit(self.path).query)})
        else:
            assert urlsplit(self.path).path == '/proxy/emby/Empty' 
        self.send_response(204); self.end_headers()

    def respond(self, value):
        data = json.dumps(value).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='vesper-emby-checks-') as temp:
        binary = str(Path(temp) / 'checks')
        subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6', '-strict-concurrency=complete',
                        str(ROOT / 'Vesper/Infrastructure/Sources/EmbyAPIClient.swift'),
                        str(ROOT / 'Tests/EmbyAPIClientChecks.swift'), '-o', binary], check=True)
        subprocess.run([binary, 'http://127.0.0.1:' + str(server.server_port)], check=True)
        # Compile the real repository and session. Extract only value contracts
        # from their iOS files; platform/keychain implementations are not tested here.
        source = (ROOT / 'Vesper/Infrastructure/Sources/SourceLibrary.swift').read_text()
        models = source[source.index('/// Stable identity'):source.index('enum SourceFailure:')]
        source = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        models += source[source.index('public struct EngineExternalSubtitle'):source.index('/// Value-only state')]
        source = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        models += source[source.index('struct TranscodedPlaybackResource'):source.index('/// The UI talks')]
        source = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        models += source[source.index('struct PlaybackVideoDetails'):source.index('struct PlaybackQueueInfo')]
        models += "\n@MainActor final class EmbyAccountStore { static let shared = EmbyAccountStore(); func client(for source: MediaSource) throws -> EmbyAPIClient { fatalError(\"Test must inject client\") } }\n"
        contracts = Path(temp) / 'Models.swift'; contracts.write_text('import Foundation\n' + models)
        units = [str(ROOT / 'Vesper/Infrastructure/Sources/EmbyAPIClient.swift'), str(contracts)]
        for name in ['Sources/EmbyIntegration.swift', 'Playback/EmbyPlaybackSession.swift']:
            unit = Path(temp) / Path(name).name
            unit.write_text((ROOT / 'Vesper/Infrastructure' / name).read_text().replace('import PlaybackContracts', ''))
            units.append(str(unit))
        subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6', '-strict-concurrency=complete',
                        *units, str(ROOT / 'Tests/EmbyRepositoryChecks.swift'), '-o', binary], check=True)
        subprocess.run([binary, 'http://127.0.0.1:' + str(server.server_port)], check=True)
    assert not EXPECTED_EPISODE_WRITES
finally:
    server.shutdown()
